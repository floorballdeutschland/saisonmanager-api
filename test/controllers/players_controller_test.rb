require 'test_helper'

class PlayersControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }])
  end

  # Hilfsmethode: Login per POST /api/v2/login und Cookie speichern
  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # 1. VM kann Lizenz für eigenes Team beantragen → 201
  test 'VM beantragt Lizenz für eigenes Team erfolgreich' do
    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    # age_eligible? gibt true zurück wenn kein deadline gesetzt
    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id },
         as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']

    @player.reload
    assert_equal 1, @player.licenses.length
    assert_equal @team.id, @player.licenses.first['team_id']
    assert_equal License::REQUESTED, @player.licenses.first['history'].last['license_status_id']
  end

  # 2. Duplikat: bereits APPROVED Lizenz für gleiche Saison+Team → 422
  test 'Doppelter Lizenzantrag für selbes Team und Saison ergibt 422' do
    existing_license = {
      'id' => Digest::UUID.uuid_v4,
      'team_id' => @team.id,
      'season_id' => @league.season_id,
      'league_class_id' => @league.league_class_id,
      'history' => [
        {
          'license_status_id' => License::APPROVED,
          'created_at' => 1.day.ago.iso8601,
          'created_by' => nil
        }
      ]
    }
    @player.update!(licenses: [existing_license])

    admin_user = create(:user, :admin)
    login_as(admin_user)

    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id },
         as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/Lizenzantrag/, body['message'])
  end

  # 3. Admin kann Lizenz genehmigen (handle_license_request mit APPROVED) → 200
  test 'Admin genehmigt Lizenzantrag erfolgreich' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    admin = create(:user, :admin)
    login_as(admin)

    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::APPROVED },
         as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']

    @player.reload
    last_status = @player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::APPROVED, last_status
  end

  # 4. Nicht-Admin kann nicht genehmigen → 403
  test 'Nicht-Admin kann keinen Lizenzantrag genehmigen' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::APPROVED },
         as: :json

    assert_response :forbidden
  end

  # 5. Rücknahme innerhalb der Karenzzeit → Lizenz komplett gelöscht
  test 'Lizenzantrag innerhalb der Karenzzeit zurückgezogen – Lizenz wird gelöscht' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 30.minutes.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']
    assert body['grace_period_deletion']

    @player.reload
    assert_empty @player.licenses
  end

  # 6. Rücknahme nach der Karenzzeit → Status WITHDRAWN, Lizenz bleibt
  test 'Lizenzantrag nach der Karenzzeit zurückgezogen – Status wird WITHDRAWN' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::REQUESTED,
                                'created_at' => 2.hours.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    vm_user = create(:user, :vm, club_id: @club.id)
    login_as(vm_user)

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :ok

    @player.reload
    assert_equal 1, @player.licenses.length
    last_status = @player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::WITHDRAWN, last_status
  end

  # --- Erst-/Zweitlizenz-Zuordnung im GF-Erwachsenenbereich ------------------

  # Zwei GF-Erwachsenen-Ligen im selben Wettbewerb (male) + je ein Team.
  def create_gf_teams
    gf_league_a = create(:league, :current_season, game_operation: @game_operation,
                                                   field_size: 'GF', league_class_id: '1fbl')
    gf_league_b = create(:league, :current_season, game_operation: @game_operation,
                                                   field_size: 'GF', league_class_id: 'rl')
    [create(:team, league: gf_league_a, club: @club), create(:team, league: gf_league_b, club: @club)]
  end

  def license_for(player, team)
    player.reload.licenses.find { |l| l['team_id'].to_i == team.id }
  end

  test 'Genehmigung mit gf_role=erstlizenz stuft die bestehende Erstlizenz zur Zweitlizenz herab' do
    team_a, team_b = create_gf_teams
    requested_id = Digest::UUID.uuid_v4
    player = create(:player, with_licenses: [
      { team: team_a, status: License::APPROVED, gf_role: 'erstlizenz' },
      { team: team_b, status: License::REQUESTED, id: requested_id }
    ])

    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{player.id}/handle_license_request",
         params: { license_id: requested_id, license_status_id: License::APPROVED, gf_role: 'erstlizenz' },
         as: :json

    assert_response :ok
    lic_a = license_for(player, team_a)
    lic_b = license_for(player, team_b)
    assert_equal 'zweitlizenz', lic_a['gf_role'], 'alte Erstlizenz muss automatisch Zweitlizenz werden'
    assert_equal 'erstlizenz',  lic_b['gf_role']
    assert_equal 'auto',   lic_a['gf_role_history'].last['source']
    assert_equal 'assign', lic_b['gf_role_history'].last['source']
    assert_equal License::APPROVED, lic_b['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
  end

  test 'Genehmigung mit gf_role für Kleinfeld-Lizenz ergibt 422 und ändert nichts' do
    kf_league = create(:league, :current_season, game_operation: @game_operation, field_size: 'KF')
    kf_team = create(:team, league: kf_league, club: @club)
    requested_id = Digest::UUID.uuid_v4
    player = create(:player, with_licenses: [{ team: kf_team, status: License::REQUESTED, id: requested_id }])

    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{player.id}/handle_license_request",
         params: { license_id: requested_id, license_status_id: License::APPROVED, gf_role: 'zweitlizenz' },
         as: :json

    assert_response :unprocessable_entity
    lic = license_for(player, kf_team)
    assert_nil lic['gf_role']
    assert_equal License::REQUESTED, lic['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i,
                 'Lizenz darf bei ungültiger Zuordnung nicht genehmigt werden'
  end

  test 'set_gf_license_role: Erstzuordnung bucht die Partner-Lizenz automatisch gegen' do
    team_a, team_b = create_gf_teams
    player = create(:player, with_licenses: [
      { team: team_a, status: License::APPROVED },
      { team: team_b, status: License::APPROVED }
    ])
    lic_b_id = license_for(player, team_b)['id']

    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_b_id, gf_role: 'zweitlizenz' },
         as: :json

    assert_response :ok
    assert_equal 'erstlizenz',  license_for(player, team_a)['gf_role'], 'einzige Partner-Lizenz wird Erstlizenz'
    assert_equal 'zweitlizenz', license_for(player, team_b)['gf_role']
  end

  test 'set_gf_license_role: Tausch nur einmal pro Saison für SBK, Admin darf überstimmen' do
    team_a, team_b = create_gf_teams
    player = create(:player, with_licenses: [
      { team: team_a, status: License::APPROVED, gf_role: 'erstlizenz' },
      { team: team_b, status: License::APPROVED, gf_role: 'zweitlizenz' }
    ])
    lic_b_id = license_for(player, team_b)['id']
    lic_a_id = license_for(player, team_a)['id']

    login_as(create(:user, :sbk_global))

    # 1. Tausch: Zweitlizenz wird Erstlizenz → Partner wird Zweitlizenz.
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_b_id, gf_role: 'erstlizenz' }, as: :json
    assert_response :ok
    assert_equal 'zweitlizenz', license_for(player, team_a)['gf_role']
    assert_equal 'erstlizenz',  license_for(player, team_b)['gf_role']

    # 2. Tausch in derselben Saison → für SBK gesperrt.
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_a_id, gf_role: 'erstlizenz' }, as: :json
    assert_response :unprocessable_entity
    assert_match(/bereits getauscht/, JSON.parse(response.body)['message'])

    # Admin darf das Limit überstimmen.
    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_a_id, gf_role: 'erstlizenz' }, as: :json
    assert_response :ok
    assert_equal 'erstlizenz',  license_for(player, team_a)['gf_role']
    assert_equal 'zweitlizenz', license_for(player, team_b)['gf_role']
  end

  test 'set_gf_license_role: leere gf_role entfernt die Zuordnung ohne Gegenbuchung' do
    team_a, team_b = create_gf_teams
    player = create(:player, with_licenses: [
      { team: team_a, status: License::APPROVED, gf_role: 'erstlizenz' },
      { team: team_b, status: License::APPROVED, gf_role: 'zweitlizenz' }
    ])
    lic_b_id = license_for(player, team_b)['id']

    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_b_id, gf_role: '' }, as: :json

    assert_response :ok
    assert_nil license_for(player, team_b)['gf_role']
    assert_equal 'erstlizenz', license_for(player, team_a)['gf_role'], 'Partner-Lizenz bleibt unverändert'
  end

  test 'set_gf_license_role: VM hat keine Berechtigung' do
    team_a, = create_gf_teams
    player = create(:player, with_licenses: [{ team: team_a, status: License::APPROVED }])
    lic_id = license_for(player, team_a)['id']

    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_id, gf_role: 'erstlizenz' }, as: :json

    assert_response :forbidden
  end

  # 7. Rücknahme einer bereits genehmigten Lizenz → 422
  test 'Rücknahme einer genehmigten Lizenz ergibt 422' do
    license_id = Digest::UUID.uuid_v4
    license = { 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                'league_class_id' => @league.league_class_id,
                'history' => [{ 'license_status_id' => License::APPROVED,
                                'created_at' => 1.day.ago.iso8601, 'created_by' => nil }] }
    @player.update!(licenses: [license])

    admin = create(:user, :admin)
    login_as(admin)

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id },
         as: :json

    assert_response :unprocessable_entity
  end
end
