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

  # admin_player: standardmäßig nur aktuelle Saison (team_id >= current_min_team),
  # mit all_licenses=true die vollständige saisonübergreifende Historie.
  test 'admin_player liefert nur aktuelle Saison; all_licenses=true liefert volle Historie' do
    admin = create(:user, :admin)

    old_league = create(:league, game_operation: @game_operation)
    old_team = create(:team, league: old_league, club: @club)
    new_team = create(:team, league: @league, club: @club)

    # current_min_team zwischen die beiden Teams legen: old_team < aktuell, new_team >= aktuell
    create(:setting, current_season_id: '18', current_min_team: new_team.id)

    old_license = {
      'id' => 'L-old',
      'team_id' => old_team.id,
      'season_id' => 17,
      'history' => [{ 'license_status_id' => License::APPROVED, 'created_at' => 2.years.ago.iso8601 }]
    }
    new_license = {
      'id' => 'L-new',
      'team_id' => new_team.id,
      'season_id' => 18,
      'history' => [{ 'license_status_id' => License::APPROVED, 'created_at' => 1.day.ago.iso8601 }]
    }
    player = create(:player, licenses: [old_license, new_license])

    login_as(admin)

    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success
    ids = JSON.parse(response.body)['licenses'].map { |l| l['id'] }
    assert_equal ['L-new'], ids

    get "/api/v2/admin/players/#{player.id}.json", params: { all_licenses: 'true' }
    assert_response :success
    ids = JSON.parse(response.body)['licenses'].map { |l| l['id'] }
    assert_includes ids, 'L-old'
    assert_includes ids, 'L-new'
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

  test 'Wettbewerbe männlich/weiblich sind getrennt: keine Gegenbuchung, eigenes Tausch-Budget' do
    team_m_a, team_m_b = create_gf_teams
    gf_w_a = create(:league, :current_season, game_operation: @game_operation,
                                              field_size: 'GF', female: true, league_class_id: '1fbl')
    gf_w_b = create(:league, :current_season, game_operation: @game_operation,
                                              field_size: 'GF', female: true, league_class_id: 'rl')
    team_w_a = create(:team, league: gf_w_a, club: @club)
    team_w_b = create(:team, league: gf_w_b, club: @club)

    player = create(:player, with_licenses: [
      { team: team_m_a, status: License::APPROVED, gf_role: 'erstlizenz' },
      { team: team_m_b, status: License::APPROVED, gf_role: 'zweitlizenz' },
      { team: team_w_a, status: License::APPROVED, gf_role: 'erstlizenz' },
      { team: team_w_b, status: License::APPROVED, gf_role: 'zweitlizenz' }
    ])

    login_as(create(:user, :sbk_global))

    # Tausch im weiblichen Wettbewerb …
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: license_for(player, team_w_b)['id'], gf_role: 'erstlizenz' }, as: :json
    assert_response :ok

    # … lässt den männlichen Wettbewerb unangetastet (keine Gegenbuchung über female hinweg) …
    assert_equal 'erstlizenz',  license_for(player, team_m_a)['gf_role']
    assert_equal 'zweitlizenz', license_for(player, team_m_b)['gf_role']
    assert_nil license_for(player, team_m_a)['gf_role_history'],
               'männliche Lizenz darf beim weiblichen Tausch keine Historie bekommen'

    # … und verbraucht dessen Tausch-Budget nicht.
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: license_for(player, team_m_b)['id'], gf_role: 'erstlizenz' }, as: :json
    assert_response :ok, 'Tausch im männlichen Wettbewerb hat ein eigenes Saisonlimit'
  end

  test 'GF-Jugendliga: keine Zuordnung möglich und keine Gegenbuchung als Partner' do
    team_a, = create_gf_teams
    youth_league = create(:league, :current_season, game_operation: @game_operation,
                                                    field_size: 'GF', age_group: 'U17 Junioren')
    youth_team = create(:team, league: youth_league, club: @club)
    player = create(:player, with_licenses: [
      { team: team_a,     status: License::APPROVED },
      { team: youth_team, status: License::APPROVED }
    ])

    login_as(create(:user, :admin))

    # Zuordnung auf der Jugend-Lizenz → 422
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: license_for(player, youth_team)['id'], gf_role: 'erstlizenz' }, as: :json
    assert_response :unprocessable_entity
    assert_nil license_for(player, youth_team)['gf_role']

    # Zuordnung auf der Erwachsenen-Lizenz: Jugend-Lizenz ist kein Partner → keine Gegenbuchung
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: license_for(player, team_a)['id'], gf_role: 'erstlizenz' }, as: :json
    assert_response :ok
    assert_equal 'erstlizenz', license_for(player, team_a)['gf_role']
    assert_nil license_for(player, youth_team)['gf_role'],
               'GF-Jugend-Lizenz darf nicht gegengebucht werden'
    assert_nil license_for(player, youth_team)['gf_role_history']
  end

  test 'Saisons sind getrennt: Vorsaison wird nicht gegengebucht, ihr Tausch zählt nicht' do
    team_a, team_b = create_gf_teams
    prev_league = create(:league, :previous_season, game_operation: @game_operation,
                                                    field_size: 'GF', league_class_id: '1fbl')
    prev_team = create(:team, league: prev_league, club: @club)

    player = create(:player, with_licenses: [
      { team: team_a,    status: License::APPROVED, gf_role: 'erstlizenz' },
      { team: team_b,    status: License::APPROVED, gf_role: 'zweitlizenz' },
      { team: prev_team, status: License::APPROVED, gf_role: 'erstlizenz', season_id: '17' }
    ])
    # Vorsaison hatte bereits einen Tausch – darf das Budget der aktuellen Saison nicht belasten.
    player.licenses.find { |l| l['team_id'] == prev_team.id }['gf_role_history'] = [
      { 'gf_role' => 'erstlizenz', 'source' => 'swap', 'created_by' => nil,
        'created_at' => 300.days.ago.iso8601 }
    ]
    player.save!
    prev_before = license_for(player, prev_team).deep_dup

    login_as(create(:user, :sbk_global))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: license_for(player, team_b)['id'], gf_role: 'erstlizenz' }, as: :json

    assert_response :ok, 'Vorsaison-Tausch darf das aktuelle Saisonlimit nicht verbrauchen'
    assert_equal 'erstlizenz',  license_for(player, team_b)['gf_role']
    assert_equal 'zweitlizenz', license_for(player, team_a)['gf_role']
    assert_equal prev_before, license_for(player, prev_team),
                 'Vorsaison-Lizenz muss unverändert bleiben'
  end

  test 'set_gf_license_role: SBK nur im eigenen Spielbetrieb' do
    # GOs brauchen eine state_association, sonst löst sich die scoped-SBK-Permission
    # zu global ([0]) auf (GOs ohne state_association gelten als national).
    sa1 = create(:state_association)
    sa2 = create(:state_association)
    go1 = GameOperation.create!(name: "GO1 #{SecureRandom.hex(4)}", short_name: "G1#{SecureRandom.hex(2)}",
                                state_association: sa1)
    go2 = GameOperation.create!(name: "GO2 #{SecureRandom.hex(4)}", short_name: "G2#{SecureRandom.hex(2)}",
                                state_association: sa2)
    gf_league = create(:league, :current_season, game_operation: go1, field_size: 'GF')
    gf_team = create(:team, league: gf_league, club: @club)
    player = create(:player, with_licenses: [{ team: gf_team, status: License::APPROVED }])
    lic_id = license_for(player, gf_team)['id']

    # SBK eines anderen Spielbetriebs → 403
    login_as(create(:user, :sbk_scoped, game_operation_id: go2.id))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_id, gf_role: 'erstlizenz' }, as: :json
    assert_response :forbidden

    # SBK des eigenen Spielbetriebs → 200
    login_as(create(:user, :sbk_scoped, game_operation_id: go1.id))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: lic_id, gf_role: 'erstlizenz' }, as: :json
    assert_response :ok
  end

  test 'Zuordnung bei der Genehmigung (assign/auto) verbraucht das Tausch-Budget nicht' do
    team_a, team_b = create_gf_teams
    requested_id = Digest::UUID.uuid_v4
    player = create(:player, with_licenses: [
      { team: team_a, status: License::APPROVED },
      { team: team_b, status: License::REQUESTED, id: requested_id }
    ])

    # Realer Ablauf: Zuordnung entsteht bei der Genehmigung (assign + auto) …
    login_as(create(:user, :admin))
    post "/api/v2/admin/players/#{player.id}/handle_license_request",
         params: { license_id: requested_id, license_status_id: License::APPROVED, gf_role: 'zweitlizenz' },
         as: :json
    assert_response :ok
    assert_equal 'erstlizenz', license_for(player, team_a)['gf_role'],
                 'unmarkierte Partner-Lizenz wird bei Wahl "Zweitlizenz" zur Erstlizenz'

    # … danach muss der erste echte Tausch durch die SBK möglich sein.
    login_as(create(:user, :sbk_global))
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: requested_id, gf_role: 'erstlizenz' }, as: :json
    assert_response :ok
    assert_equal 'erstlizenz',  license_for(player, team_b)['gf_role']
    assert_equal 'zweitlizenz', license_for(player, team_a)['gf_role']
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

  # 8. Öffentliche Spielerstatistik: pro Saison aggregiert; laufende und
  # abgeschlossene Saisons werden getrennt berechnet (Cache-Split in #stats)
  # und müssen zusammen wieder die komplette Karriere ergeben.
  test 'GET players/:id/stats aggregiert Tore pro Saison über den Saison-Split' do
    arena = create(:arena)
    old_league = create(:league, :previous_season, game_operation: @game_operation)
    old_team = create(:team, league: old_league, club: @club)

    [[@league, @team, 1], [old_league, old_team, 2]].each do |league, team, goals|
      game_day = GameDay.create!(league: league, arena: arena, club: @club, number: 1, date: '2025-01-01')
      guest = create(:team, league: league, club: @club)
      events = (1..goals).map do |i|
        { 'period' => 1, 'home_goals' => i, 'guest_goals' => 0, 'home_number' => 7, 'row' => i }
      end
      Game.create!(
        game_day: game_day, home_team: team, guest_team: guest,
        started: true, ended: true, forfait: 0, overtime: false, legacy: false,
        events: events,
        players: { 'home' => [{ 'trikot_number' => 7, 'player_id' => @player.id }], 'guest' => [] }
      )
    end

    get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal([18, 17], body['seasons'].map { |s| s['season_id'] })
    assert_equal 1, body['seasons'][0]['leagues'][0]['goals']
    assert_equal 2, body['seasons'][1]['leagues'][0]['goals']
    assert_equal 2, body['totals']['games']
    assert_equal 3, body['totals']['goals']
  end

  # Der Endpunkt ist per X-Api-Key erreichbar und die Spieler-ID frei
  # durchzählbar. Geburtsdatum und Geschlecht dürfen deshalb nicht mitgehen.
  test 'GET players/:id/stats liefert weder Geburtsdatum noch Geschlecht' do
    get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }
    assert_response :success

    player = JSON.parse(response.body)['player']
    assert_equal @player.id, player['id']
    refute_includes player.keys, 'birthdate'
    refute_includes player.keys, 'gender'
  end

  # 9. Nicht nur Tore: Assists und Strafminuten (2/4/5/10/25-Multiplikatoren)
  # sind die fehleranfälligsten Aggregate und werden hier explizit geprüft.
  test 'GET players/:id/stats aggregiert Assists und Strafminuten' do
    events = [
      # Tor + Assist an denselben Spieler (Trikot 7)
      { 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 7, 'row' => 1 },
      # Assist ohne eigenes Tor: Torschütze (Trikot 99) nicht in der Aufstellung,
      # Vorlage (Trikot 7) schon → nur der Assist wird @player gutgeschrieben.
      { 'period' => 1, 'home_goals' => 2, 'guest_goals' => 0, 'home_number' => 99, 'home_assist' => 7, 'row' => 2 },
      # 2-Minuten-Strafe (penalty_mapping inline → keine Setting-Penalty-Config nötig)
      { 'period' => 1, 'penalty_id' => 1, 'penalty_mapping' => 'penalty_2', 'home_number' => 7, 'row' => 3 }
    ]
    create_stats_game(@league, @team, events)

    get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }
    assert_response :success

    league = JSON.parse(response.body)['seasons'][0]['leagues'][0]
    assert_equal 1, league['goals']
    assert_equal 1, league['assists']
    assert_equal 2, league['penalty_minutes']
  end

  # 10. Korrekturen an einem Spiel einer ABGESCHLOSSENEN Saison müssen sofort
  # sichtbar werden — der Langzeit-Cache (1 Woche) wird über den after_commit-
  # Hook des Spiels invalidiert (sonst blieben Edits bis zum TTL-Ablauf stale).
  test 'GET players/:id/stats invalidiert den Langzeit-Cache bei Edit an abgeschlossener Saison' do
    old_league = create(:league, :previous_season, game_operation: @game_operation)
    old_team = create(:team, league: old_league, club: @club)
    game = create_stats_game(old_league, old_team,
                             [{ 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 7, 'row' => 1 }])

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }
      assert_equal 1, JSON.parse(response.body)['totals']['goals']

      # Zweites Tor ergänzen → ohne Invalidierung bliebe der Cache bei 1.
      game.update!(events: game.events + [{ 'period' => 1, 'home_goals' => 2, 'guest_goals' => 0, 'home_number' => 7, 'row' => 2 }])

      get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }
      assert_equal 2, JSON.parse(response.body)['totals']['goals']
    end
  end

  # 11. Anzeige-Namen werden frisch aufgelöst, nicht mitgecacht: eine
  # Liga-Umbenennung erscheint sofort, obwohl der numerische Cache (der bei
  # einer reinen Umbenennung NICHT invalidiert wird) unverändert bleibt.
  test 'GET players/:id/stats zeigt Liga-Umbenennung sofort trotz gecachter Aggregate' do
    old_league = create(:league, :previous_season, game_operation: @game_operation, name: 'Alt-Liga')
    old_team = create(:team, league: old_league, club: @club)
    create_stats_game(old_league, old_team,
                      [{ 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 7, 'row' => 1 }])

    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }
      assert_equal 'Alt-Liga', JSON.parse(response.body)['seasons'][0]['leagues'][0]['league_name']

      old_league.update!(name: 'Neu-Liga')

      get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => 'test-key-for-smoke-tests' }
      assert_equal 'Neu-Liga', JSON.parse(response.body)['seasons'][0]['leagues'][0]['league_name']
    end
  end

  # vm_players_index: current_licenses listet alle Lizenzen der laufenden
  # Saison mit Liga-Kürzel (Fallback: Liganame), höchste Liga zuerst; der
  # erste Eintrag speist die bestehenden current_license_status-Felder.
  test 'vm_players_index liefert current_licenses pro Liga mit Kürzel' do
    vm = create(:user, :vm, club_id: @club.id)

    @league.update!(short_name: '1. FBL', league_class_id: '1fbl')
    rl_league = create(:league, :current_season, game_operation: @game_operation,
                                                 name: 'Regionalliga Ost', short_name: nil, league_class_id: 'rl')
    rl_team = create(:team, league: rl_league, club: @club)
    rl_team2 = create(:team, league: rl_league, club: @club)
    rl_team3 = create(:team, league: rl_league, club: @club)
    old_league = create(:league, :previous_season, game_operation: @game_operation, short_name: 'Alt')
    old_team = create(:team, league: old_league, club: @club)

    player = create(
      :player,
      clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }],
      licenses: [
        { 'id' => 'L-rl', 'team_id' => rl_team.id, 'league_class_id' => 'rl',
          'history' => [{ 'license_status_id' => License::REQUESTED, 'created_at' => 1.day.ago.iso8601 }] },
        { 'id' => 'L-fbl', 'team_id' => @team.id, 'league_class_id' => '1fbl',
          'history' => [{ 'license_status_id' => License::APPROVED, 'created_at' => 2.days.ago.iso8601 }] },
        # Gleiche Liga + gleicher Status über ein zweites Team → dedupliziert.
        { 'id' => 'L-rl2', 'team_id' => rl_team2.id, 'league_class_id' => 'rl',
          'history' => [{ 'license_status_id' => License::REQUESTED, 'created_at' => 3.hours.ago.iso8601 }] },
        # Lizenz ohne History (Altdaten-Fall) wird übersprungen, kein 500.
        { 'id' => 'L-kaputt', 'team_id' => rl_team3.id, 'league_class_id' => 'rl', 'history' => [] },
        # Lizenz aus einer früheren Saison taucht nicht auf.
        { 'id' => 'L-alt', 'team_id' => old_team.id, 'league_class_id' => '1fbl',
          'history' => [{ 'license_status_id' => License::APPROVED, 'created_at' => 1.year.ago.iso8601 }] }
      ]
    )

    login_as(vm)
    get '/api/v2/admin/vm/players.json', params: { club_id: @club.id }
    assert_response :success

    rows = JSON.parse(response.body)
    row = rows.find { |p| p['id'] == player.id }
    assert_equal License::APPROVED, row['current_license_status_id']
    assert_equal [
      { 'license_status_id' => License::APPROVED, 'license_status' => 'erteilt',
        'league_id' => @league.id, 'league_short_name' => '1. FBL' },
      { 'license_status_id' => License::REQUESTED, 'license_status' => 'beantragt',
        'league_id' => rl_league.id, 'league_short_name' => 'Regionalliga Ost' }
    ], row['current_licenses']

    # Spieler ohne Lizenz in der laufenden Saison bekommt kein current_licenses.
    no_license_row = rows.find { |p| p['id'] == @player.id }
    assert_nil no_license_row['current_licenses']
    assert_nil no_license_row['current_license_status_id']
  end

  # Reload-Fall: eine gerade deaktivierte Spielerin muss in der Vereinsliste
  # bleiben. Player#deactivate! schliesst ihre Zugehoerigkeit (valid_until = jetzt),
  # ohne den include_deactivated-Zweig fiel sie doppelt aus dem Ergebnis – der
  # Schalter "N deaktiviert einblenden" verschwand nach jedem Neuladen und die
  # Reaktivierung war aus der Liste nicht mehr erreichbar.
  test 'vm_players_index behaelt deaktivierte Spieler nach dem Neuladen' do
    vm = create(:user, :vm, club_id: @club.id)
    deaktiviert = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    # Regulaerer Vereinsaustritt (nicht deaktiviert) bleibt ausgeblendet.
    ausgetreten = create(:player, clubs: [{ 'club_id' => @club.id, 'valid_until' => 2.years.ago.iso8601,
                                            'valid_set_by' => vm.id }])

    login_as(vm)
    post "/api/v2/admin/players/#{deaktiviert.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :success

    get '/api/v2/admin/vm/players.json', params: { club_id: @club.id }
    assert_response :success

    rows = JSON.parse(response.body)
    row = rows.find { |p| p['id'] == deaktiviert.id }
    assert row.present?, 'deaktivierte Spielerin fehlt in der Vereinsliste'
    assert row['deactivated_at'].present?, 'deactivated_at fehlt im Listeneintrag'
    assert_nil(rows.find { |p| p['id'] == ausgetreten.id })

    # Nach der Reaktivierung ist sie wieder regulaer in der Liste.
    post "/api/v2/admin/players/#{deaktiviert.id}/reactivate"
    assert_response :success

    get '/api/v2/admin/vm/players.json', params: { club_id: @club.id }
    reaktiviert = JSON.parse(response.body).find { |p| p['id'] == deaktiviert.id }
    assert reaktiviert.present?
    assert_nil reaktiviert['deactivated_at']
  end

  # Der internationale Transfer laeuft ueber FD und IFF ausserhalb dieses Systems.
  # Im System bleibt die Deaktivierung mit dem passenden Grund, damit der Fall in
  # der Historie nicht als "Sonstiges" verschwindet.
  test 'deactivate akzeptiert Wechsel ins Ausland und weist unbekannte Gruende ab' do
    vm = create(:user, :vm, club_id: @club.id)
    ausland = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    unbekannt = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])

    login_as(vm)
    post "/api/v2/admin/players/#{ausland.id}/deactivate", params: { reason: 'Wechsel ins Ausland' }
    assert_response :success
    assert_equal 'Wechsel ins Ausland', ausland.reload.deactivation_reason
    assert ausland.deactivated_at.present?

    post "/api/v2/admin/players/#{unbekannt.id}/deactivate", params: { reason: 'Wechsel nach Schweden' }
    assert_response :unprocessable_entity
    assert_nil unbekannt.reload.deactivated_at
  end

  # Eine zusammengefuehrte Dublette ist nur deshalb deaktiviert, weil merge_into! sie
  # ersetzt hat. Sie darf weder in der Vereinsliste stehen noch reaktiviert werden,
  # sonst gibt es das zweite Profil derselben Person wieder.
  test 'zusammengefuehrte Dublette bleibt aus Liste und Reaktivierung heraus' do
    vm = create(:user, :vm, club_id: @club.id)
    master = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    dublette = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    dublette.merge_into!(master, vm.id)

    login_as(vm)
    get '/api/v2/admin/vm/players.json', params: { club_id: @club.id }
    assert_response :success

    ids = JSON.parse(response.body).map { |p| p['id'] }
    assert_includes ids, master.id
    refute_includes ids, dublette.id

    post "/api/v2/admin/players/#{dublette.id}/reactivate"
    assert_response :unprocessable_entity
    assert_match(/zusammengeführt/, JSON.parse(response.body)['message'])
    assert dublette.reload.deactivated_at.present?
  end

  # --- Spielbetriebs-Scope der SBK-Rolle im Lizenzwesen -----------------------
  # Der Antragspfad prüfte nur, DASS eine SBK-Rolle existiert, nicht für welchen
  # Spielbetrieb: ein SBK eines Landesverbands konnte in jeder Liga jedes anderen
  # Verbands Lizenzen beantragen und zurückziehen.

  test 'SBK eines fremden Spielbetriebs darf keine Lizenz beantragen' do
    other_go = create(:game_operation)
    login_as(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id }, as: :json

    assert_response :forbidden
    assert_match(/Keine Berechtigung/, JSON.parse(response.body)['message'])
    assert_empty @player.reload.licenses
  end

  test 'SBK des eigenen Spielbetriebs darf weiterhin Lizenz beantragen' do
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id }, as: :json

    assert_response :ok
    assert_equal 1, @player.reload.licenses.length
  end

  test 'Globaler SBK darf in jedem Spielbetrieb Lizenz beantragen' do
    login_as(create(:user, :sbk_global))

    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id }, as: :json

    assert_response :ok
    assert_equal 1, @player.reload.licenses.length
  end

  # Der Fall aus der Praxis: SBK eines LV, gleichzeitig VM eines Vereins mit
  # Bundesliga-Team. Ein reiner GO-Check ohne additive Rollen hätte ihn genau
  # bei seiner eigenen Mannschaft ausgesperrt.
  test 'SBK mit VM-Rolle darf für eigenen Verein außerhalb seines Spielbetriebs beantragen' do
    other_go = create(:game_operation)
    user = create(:user, permissions: [
      { 'user_group_id' => 2, 'game_operation_id' => other_go.id },
      { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => @club.id }
    ])
    login_as(user)

    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: @team.id }, as: :json

    assert_response :ok
    assert_equal 1, @player.reload.licenses.length
  end

  test 'SBK eines fremden Spielbetriebs darf Lizenzantrag nicht zurückziehen' do
    license_id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => license_id, 'team_id' => @team.id, 'season_id' => @league.season_id,
                                 'history' => [{ 'license_status_id' => License::REQUESTED,
                                                 'created_at' => 1.day.ago.iso8601 }] }])
    other_go = create(:game_operation)
    login_as(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/user/players/#{@player.id}/withdraw_license",
         params: { license_id: license_id }, as: :json

    assert_response :forbidden
    last = @player.reload.licenses.first['history'].last
    assert_equal License::REQUESTED, last['license_status_id']
  end

  test 'Lizenzliste einer Liga bleibt dem SBK eines fremden Spielbetriebs verwehrt' do
    other_go = create(:game_operation)
    login_as(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/user/leagues/#{@league.id}/licenses"

    assert_response :forbidden
  end

  # --- Spieler muss zum Verein des Teams gehören ------------------------------
  # Die player_id kommt aus der URL und war ungeprüft: ein TM konnte jeden
  # beliebigen Spieler des Gesamtbestands in sein eigenes Team lizenzieren.

  test 'Lizenzantrag für Spieler ohne Mitgliedschaft im Verein des Teams ergibt 422' do
    foreign_player = create(:player, clubs: [{ 'club_id' => create(:club).id, 'home_club' => true }])
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/user/players/#{foreign_player.id}/request_license",
         params: { team_id: @team.id }, as: :json

    assert_response :unprocessable_entity
    assert_match(/Mitgliedschaft/, JSON.parse(response.body)['message'])
    assert_empty foreign_player.reload.licenses
  end

  test 'Lizenzantrag mit abgelaufener Vereinsmitgliedschaft ergibt 422' do
    expired = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                        'valid_until' => 1.month.ago.to_date.iso8601 }])
    login_as(create(:user, :vm, club_id: @club.id))

    post "/api/v2/user/players/#{expired.id}/request_license",
         params: { team_id: @team.id }, as: :json

    assert_response :unprocessable_entity
    assert_match(/Mitgliedschaft/, JSON.parse(response.body)['message'])
  end

  # Datenfehler dürfen nicht als Rechte-Absage erscheinen: Der Spielbetriebs-
  # Scope wird aus der Liga abgeleitet, ohne Liga gibt es keinen. Die zuständige
  # SBK muss die zutreffende Meldung bekommen, nicht "Keine Berechtigung".
  test 'Team ohne Liga meldet den Datenfehler statt einer Rechte-Absage' do
    orphan = create(:team, league: @league, club: @club)
    orphan.update_columns(league_id: nil)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/user/players/#{@player.id}/request_license",
         params: { team_id: orphan.id }, as: :json

    assert_response :unprocessable_entity
    assert_match(/keiner Liga zugeordnet/, JSON.parse(response.body)['message'])
  end

  # Ein unlesbares valid_until darf keine Mitgliedschaft begründen, der Fall
  # muss aber gemeldet werden, sonst ist die 422 nicht von einer echten
  # Nicht-Mitgliedschaft zu unterscheiden.
  test 'Unlesbares valid_until zaehlt nicht als Mitgliedschaft und wird gemeldet' do
    broken = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                                       'valid_until' => '0000-00-00' }])
    login_as(create(:user, :vm, club_id: @club.id))

    logged = []
    Rails.logger.stub(:error, ->(msg) { logged << msg }) do
      post "/api/v2/user/players/#{broken.id}/request_license",
           params: { team_id: @team.id }, as: :json
    end

    assert_response :unprocessable_entity
    assert_match(/Mitgliedschaft/, JSON.parse(response.body)['message'])
    assert(logged.any? { |m| m.to_s.include?('valid_until') }, "Datenfehler wurde nicht gemeldet: #{logged.inspect}")
  end

  # syndicate_clubs gesetzt, syndicate-Flag nicht: Team#all_club_ids blendet die
  # Partnervereine dann aus, der VM-Zweig der Rechteprüfung nicht. Beide Seiten
  # müssen dieselbe Vereinsmenge benutzen, sonst kommt der VM des Partnervereins
  # durch die Rechteprüfung und scheitert danach an der Mitgliedschaft.
  test 'Partnerverein ohne gesetztes syndicate-Flag kann trotzdem beantragen' do
    partner = create(:club)
    sg_team = create(:team, league: @league, club: @club, syndicate: false, syndicate_clubs: [partner.id])
    partner_player = create(:player, clubs: [{ 'club_id' => partner.id, 'home_club' => true }])
    login_as(create(:user, :vm, club_id: partner.id))

    post "/api/v2/user/players/#{partner_player.id}/request_license",
         params: { team_id: sg_team.id }, as: :json

    assert_response :ok
    assert_equal 1, partner_player.reload.licenses.length
  end

  test 'Admin darf auch ohne Vereinsmitgliedschaft beantragen' do
    foreign_player = create(:player, clubs: [{ 'club_id' => create(:club).id, 'home_club' => true }])
    login_as(create(:user, :admin))

    post "/api/v2/user/players/#{foreign_player.id}/request_license",
         params: { team_id: @team.id }, as: :json

    assert_response :ok
    assert_equal 1, foreign_player.reload.licenses.length
  end

  # admin_players_index (Spielerliste eines Vereins in der Spielerverwaltung):
  # Der Alt-Eintrag im game_operations_hash gibt keinen Zugriff mehr, auch nicht,
  # wenn er den eigenen Spielbetrieb nennt. Auf Produktion konnte eine SBK
  # darueber 2.513 Spielerprofile fremder Vereine auflisten, ohne dass eine
  # Freigabe erteilt war.
  test 'admin_players_index sperrt Verein trotz Alt-Eintrag auf den eigenen Spielbetrieb' do
    fremder_go = create(:game_operation)
    # Landesverband beim fremden Spielbetrieb, im Alt-Eintrag der eigene: genau
    # der Weg, ueber den der Zugriff frueher entstand.
    gast_club = create(:club, state_association_id: fremder_go.state_association_id,
                              game_operations_hash: [{ 'game_operation_id' => @game_operation.id,
                                                       'home_game_operation' => true }])
    create(:player, clubs: [{ 'club_id' => gast_club.id, 'home_club' => true }])

    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    get "/api/v2/admin/clubs/#{gast_club.id}/players"

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # Gegenprobe und zugleich Bugfix: Die Methode kannte die Vereins-Freigabe
  # bisher gar nicht. Ein freigegebener Verein war ueber admin/clubs/:id lesbar,
  # seine Spielerliste antwortete aber leer.
  test 'admin_players_index erlaubt freigegebenen Verein' do
    grantor_sa = create(:state_association)
    grantor_go = create(:game_operation, state_association_id: grantor_sa.id)
    club = create(:club, state_association_id: grantor_sa.id, game_operation: grantor_go)
    spieler = create(:player, clubs: [{ 'club_id' => club.id, 'home_club' => true }])
    StateAssociationRelease.create!(grantor_state_association_id: grantor_sa.id,
                                    recipient_game_operation_id: @game_operation.id,
                                    season_id: Setting.current_season_id)

    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    get "/api/v2/admin/clubs/#{club.id}/players"

    assert_response :success
    assert_equal([spieler.id], JSON.parse(response.body)['players'].map { |p| p['id'] })
  end

  # --- Heimatverein der SBK-Pruefung: nur gueltige clubs-Eintraege ------------
  # Nach einem Heimatvereinswechsel stehen mehrere Eintraege mit home_club: true
  # im Hash; der alte ist per valid_until beendet. Die Pruefung nahm den ERSTEN
  # und sperrte damit die zustaendige SBK aus (Prod: 3.012 Spieler, api#389).

  test 'SBK des gueltigen Heimatvereins darf Spieler trotz abgelaufenem Alt-Eintrag oeffnen' do
    heim_club = create(:club, game_operation: @game_operation)
    alt_go = create(:game_operation)
    alt_club = create(:club, game_operation: alt_go)
    player = create(:player, clubs: [
      { 'club_id' => alt_club.id, 'home_club' => true, 'valid_until' => 1.year.ago.iso8601 },
      { 'club_id' => heim_club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 }
    ])

    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    get "/api/v2/admin/players/#{player.id}.json"

    assert_response :success
    assert_equal player.id, JSON.parse(response.body)['id']
  end

  # Gegenprobe: Der abgelaufene Eintrag gibt auch keinen Zugriff mehr. Vorher
  # war es genau umgekehrt, nur die Alt-SBK kam an das Profil.
  test 'SBK des abgelaufenen Alt-Eintrags darf den Spieler nicht mehr oeffnen' do
    heim_club = create(:club, game_operation: @game_operation)
    alt_go = create(:game_operation)
    alt_club = create(:club, game_operation: alt_go)
    player = create(:player, clubs: [
      { 'club_id' => alt_club.id, 'home_club' => true, 'valid_until' => 1.year.ago.iso8601 },
      { 'club_id' => heim_club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 }
    ])

    login_as(create(:user, :sbk_scoped, game_operation_id: alt_go.id))
    get "/api/v2/admin/players/#{player.id}.json"

    assert_response :forbidden
  end

  # Bewusst unveraendert: Ohne gueltigen Heimateintrag bleibt das Profil fuer
  # jede Landes-SBK gesperrt (Prod: 76 aktive Spieler). Das ist ein Datenproblem
  # und in api#389 ausdruecklich nicht Teil des Fixes.
  test 'Spieler ohne gueltigen Heimateintrag bleibt fuer die Landes-SBK gesperrt' do
    heim_club = create(:club, game_operation: @game_operation)
    player = create(:player, clubs: [
      { 'club_id' => heim_club.id, 'home_club' => true, 'valid_until' => 1.year.ago.iso8601 }
    ])

    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    get "/api/v2/admin/players/#{player.id}.json"

    assert_response :forbidden
  end

  test 'Globaler SBK oeffnet auch Spieler ohne gueltigen Heimateintrag' do
    player = create(:player, clubs: [
      { 'club_id' => create(:club).id, 'home_club' => true, 'valid_until' => 1.year.ago.iso8601 }
    ])

    login_as(create(:user, :sbk_global))
    get "/api/v2/admin/players/#{player.id}.json"

    assert_response :success
  end

  # --- Rücknahme und Zusammenführen ohne gültige Heimat-Zugehörigkeit -------
  #
  # Die Profilansicht bleibt in diesem Fall gesperrt, das ist entschieden
  # (api#389, Datenproblem). Zwei Aktionen brauchen trotzdem eine Zuständigkeit,
  # sonst hindert die Sperre die zuständige Stelle an ihrer eigenen Arbeit.

  # Ein gemeinsamer Zeitpunkt für `valid_until` und `deactivated_at`, auf die
  # Sekunde gerundet: `iso8601` schneidet die Mikrosekunden ab, und
  # Player::DEACTIVATION_CLOSE_WINDOW ist nur eine Sekunde breit. Zwei getrennte
  # `7.days.ago`-Aufrufe fielen sonst gelegentlich auseinander.
  def deaktiviert_am
    @deaktiviert_am ||= 7.days.ago.change(usec: 0)
  end

  # Ein Verein, für den dieser Spielbetrieb zuständig ist. Die Factory übersetzt
  # `game_operation:` in den Landesverband des Spielbetriebs.
  def club_in(game_operation)
    create(:club, game_operation: game_operation)
  end

  def fremder_spielbetrieb
    create(:game_operation, state_association_id: create(:state_association).id)
  end

  # `deactivate!` stempelt ALLE Zugehörigkeiten, auch die Heimat. Ohne den
  # Rückfall durfte eine Landes-SBK deaktivieren, aber ab dem Tag danach nicht
  # mehr zurücknehmen.
  test 'gescopte SBK reaktiviert ein vor Tagen deaktiviertes Profil' do
    admin = create(:user, :admin)
    heim_club = create(:club, game_operation: @game_operation)
    deaktiviert = create(:player, clubs: [{ 'club_id' => heim_club.id, 'home_club' => true,
                                            'valid_until' => deaktiviert_am.iso8601,
                                            'valid_set_by' => admin.id }],
                                  deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{deaktiviert.id}/reactivate"

    assert_response :success
    assert_nil deaktiviert.reload.deactivated_at
  end

  # Gegenprobe: Der Rückfall reicht nur so weit wie der eigene Spielbetrieb.
  test 'fremde SBK reaktiviert ein deaktiviertes Profil nicht' do
    admin = create(:user, :admin)
    fremd_sa = create(:state_association)
    fremd_go = create(:game_operation, state_association_id: fremd_sa.id)
    heim_club = create(:club, game_operation: @game_operation)
    deaktiviert = create(:player, clubs: [{ 'club_id' => heim_club.id, 'home_club' => true,
                                            'valid_until' => deaktiviert_am.iso8601,
                                            'valid_set_by' => admin.id }],
                                  deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: fremd_go.id))

    post "/api/v2/admin/players/#{deaktiviert.id}/reactivate"

    assert_response :forbidden
    assert deaktiviert.reload.deactivated_at.present?
  end

  # Die Reihenfolge im clubs-Hash ist NICHT chronologisch: Player#_merge_clubs
  # sortiert nach created_at, Altdaten ohne created_at rutschen nach vorn. Ein
  # geschlossener Eintrag kann deshalb HINTER einem offenen stehen. Ohne den
  # Riegel „gültige Heimat entscheidet allein" käme die SBK des geschlossenen
  # Eintrags an ein Profil, das im anderen Verband beheimatet ist.
  test 'gueltige Heimat schlaegt den hinteren, geschlossenen Eintrag' do
    admin = create(:user, :admin)
    heimat_club = create(:club, game_operation: @game_operation)
    fremd_sa = create(:state_association)
    fremd_go = create(:game_operation, state_association_id: fremd_sa.id)
    fremd_club = create(:club, game_operation: fremd_go)
    # Offener Legacy-Eintrag ohne created_at zuerst, dahinter der geschlossene.
    player = create(:player, clubs: [
      { 'club_id' => heimat_club.id, 'home_club' => true },
      { 'club_id' => fremd_club.id, 'home_club' => true,
        'created_at' => 2.years.ago.iso8601, 'valid_until' => 2.years.ago.iso8601 }
    ], deactivated_at: deaktiviert_am, deactivated_by: admin.id)

    login_as(create(:user, :sbk_scoped, game_operation_id: fremd_go.id))

    post "/api/v2/admin/players/#{player.id}/reactivate"
    assert_response :forbidden, 'der fremde Verband darf nicht über den hinteren Eintrag herankommen'

    master = create(:player, clubs: [{ 'club_id' => fremd_club.id, 'home_club' => true }])
    post "/api/v2/admin/players/#{master.id}/merge", params: { secondary_id: player.id }, as: :json
    assert_response :forbidden, 'und ein fremdes Profil auch nicht als Dublette hereinziehen'
    assert_nil player.reload.merged_into_id
  end

  # Der Rückfall trägt nur, wenn die Deaktivierung die Zugehörigkeit selbst
  # geschlossen hat. Endete sie lange vorher, gibt reactivate! sie nicht zurück,
  # das Profil bliebe ohne Zuständigkeit — und reactivate antwortet mit full_hash,
  # wäre also nur ein Lesepfad auf die zurückgehaltenen Profildaten.
  test 'Rueckfall greift nicht, wenn die Heimat schon vor der Deaktivierung endete' do
    admin = create(:user, :admin)
    vm = create(:user, :vm)
    heim_club = create(:club, game_operation: @game_operation)
    player = create(:player, clubs: [{ 'club_id' => heim_club.id, 'home_club' => true,
                                       'valid_until' => 3.years.ago.iso8601,
                                       'valid_set_by' => vm.id }],
                             deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{player.id}/reactivate"

    assert_response :forbidden
    assert player.reload.deactivated_at.present?
  end

  # Grenze der Regel, bewusst so: Ist der jüngste Heimat-Eintrag nicht auflösbar
  # (fehlende `club_id`, gelöschter Verein), gibt es auch NACH der Rücknahme keinen
  # zuständigen Verband, `Player#home_club` liefert dort nil. Die Absage ist damit
  # dieselbe wie am Profil selbst; ein Ja wäre nur ein Blick in Daten, für die
  # niemand zuständig ist. Solche Profile brauchen Datenpflege — Haltung aus api#389.
  test 'unaufloesbarer juengster Heimat-Eintrag bleibt eine Absage' do
    admin = create(:user, :admin)
    heim_club = create(:club, game_operation: @game_operation)
    player = create(:player, clubs: [
      { 'club_id' => heim_club.id, 'home_club' => true,
        'valid_until' => deaktiviert_am.iso8601, 'valid_set_by' => admin.id },
      { 'home_club' => true, 'valid_until' => deaktiviert_am.iso8601,
        'valid_set_by' => admin.id }
    ], deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{player.id}/reactivate"

    assert_response :forbidden
  end

  # `'false'` als String ist truthy. Ein Zweitspielrecht mit diesem Altdaten-Wert
  # darf keine Zuständigkeit über einen Verein verschaffen, bei dem der Spieler
  # nie beheimatet war.
  test 'home_club als String false zaehlt nicht als Heimat-Eintrag' do
    admin = create(:user, :admin)
    gast_club = create(:club, game_operation: @game_operation)
    player = create(:player, clubs: [{ 'club_id' => gast_club.id, 'home_club' => 'false',
                                       'valid_until' => deaktiviert_am.iso8601,
                                       'valid_set_by' => admin.id }],
                             deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{player.id}/reactivate"

    assert_response :forbidden
  end

  # Zuständig für die Rücknahme ist, wer beim Deaktivieren zuständig war. Eine
  # Zugehörigkeit, die schon Jahre vorher endete, begründet das nicht — auch dann
  # nicht, wenn ein ANDERER Eintrag von der Deaktivierung geschlossen wurde.
  test 'fremder Verband kommt nicht ueber einen alten Eintrag an die Ruecknahme' do
    admin = create(:user, :admin)
    vm = create(:user, :vm)
    fremd_go = fremder_spielbetrieb
    # Der fremde Verband: Zugehörigkeit vor vier Jahren durch einen VM beendet.
    fremd_club = club_in(fremd_go)
    # Der eigene: die Zugehörigkeit, welche die Deaktivierung geschlossen hat.
    heim_club = club_in(@game_operation)
    player = create(:player, clubs: [
      { 'club_id' => fremd_club.id, 'home_club' => true,
        'valid_until' => 4.years.ago.iso8601, 'valid_set_by' => vm.id },
      { 'club_id' => heim_club.id, 'home_club' => true,
        'valid_until' => deaktiviert_am.iso8601, 'valid_set_by' => admin.id }
    ], deactivated_at: deaktiviert_am, deactivated_by: admin.id)

    login_as(create(:user, :sbk_scoped, game_operation_id: fremd_go.id))
    post "/api/v2/admin/players/#{player.id}/reactivate"
    assert_response :forbidden

    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    post "/api/v2/admin/players/#{player.id}/reactivate"
    assert_response :success, 'der Verband der geschlossenen Zugehörigkeit darf'
  end

  # Gegenstück zum String-`'false'`-Test: Ein OFFENER Gast-Eintrag mit diesem
  # Altdaten-Wert darf nicht als gültige Heimat gelten, sonst verwehrt er dem
  # zuständigen Verband seine eigene Rücknahme.
  test 'offener Gast-Eintrag mit home_club false blockiert die Ruecknahme nicht' do
    admin = create(:user, :admin)
    heim_club = club_in(@game_operation)
    gast_club = club_in(fremder_spielbetrieb)
    player = create(:player, clubs: [
      { 'club_id' => heim_club.id, 'home_club' => true,
        'valid_until' => deaktiviert_am.iso8601, 'valid_set_by' => admin.id },
      { 'club_id' => gast_club.id, 'home_club' => 'f' }
    ], deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{player.id}/reactivate"

    assert_response :success
  end

  # War die Heimat-Zugehörigkeit schon VOR der Deaktivierung befristet, sichert
  # `deactivate!` diese Befristung unter VALID_BEFORE_DEACTIVATION und
  # `reactivate!` setzt sie zurück, statt die Zugehörigkeit unbefristet zu öffnen.
  # Die Kopie muss das nachbilden: Liegt das gesicherte Datum in der
  # Vergangenheit, ist die Zugehörigkeit auch nach der Rücknahme abgelaufen, und
  # es gibt keine Zuständigkeit. Ohne diese Zeile hielte die Kopie sie für offen.
  test 'gesicherte Befristung zaehlt: abgelaufen bleibt abgelaufen' do
    admin = create(:user, :admin)
    heim_club = club_in(@game_operation)
    player = create(:player, clubs: [
      { 'club_id' => heim_club.id, 'home_club' => true,
        'valid_until' => deaktiviert_am.iso8601, 'valid_set_by' => admin.id,
        Player::VALID_BEFORE_DEACTIVATION => { 'valid_until' => 2.years.ago.iso8601,
                                               'valid_set_by' => admin.id } }
    ], deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{player.id}/reactivate"

    assert_response :forbidden
  end

  # Gegenprobe: Liegt die gesicherte Befristung in der Zukunft, ist die
  # Zugehörigkeit nach der Rücknahme gültig, und die Zuständigkeit besteht.
  test 'gesicherte Befristung in der Zukunft laesst die Ruecknahme zu' do
    admin = create(:user, :admin)
    heim_club = club_in(@game_operation)
    player = create(:player, clubs: [
      { 'club_id' => heim_club.id, 'home_club' => true,
        'valid_until' => deaktiviert_am.iso8601, 'valid_set_by' => admin.id,
        Player::VALID_BEFORE_DEACTIVATION => { 'valid_until' => 1.year.from_now.iso8601,
                                               'valid_set_by' => admin.id } }
    ], deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{player.id}/reactivate"

    assert_response :success
  end

  # Ohne jeden Heimat-Eintrag gibt es keine Zuständigkeit, die der Rückfall finden
  # könnte. Die Absage bleibt auch beim Reaktivieren.
  test 'ohne Heimat-Eintrag bleibt es auch beim Reaktivieren bei der Absage' do
    admin = create(:user, :admin)
    ohne_heimat = create(:player, clubs: [{ 'club_id' => @club.id }],
                                  deactivated_at: deaktiviert_am, deactivated_by: admin.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    post "/api/v2/admin/players/#{ohne_heimat.id}/reactivate"

    assert_response :forbidden
  end

  private

  # Beendetes Spiel mit @player (Trikot 7) in der Heim-Aufstellung.
  # admin_player_update, Anlege-Zweig. Der Endpunkt war bis hierher ohne
  # Testabdeckung, obwohl an ihm die vereinsgebundene Berechtigung hängt.
  test 'TM legt im Verein der eigenen Mannschaft eine Spielerin an' do
    login_as(create(:user, :tm, team_id: @team.id))

    assert_difference 'Player.count', 1 do
      post '/api/v2/admin/players.json',
           params: { id: 0, club_id: @club.id, first_name: 'Neu', last_name: 'Zugang',
                     birthdate: '2005-03-01', gender: 'w', nation_id: '1' },
           as: :json
    end

    assert_response :created
    player = Player.find(JSON.parse(response.body)['id'])
    club_ids = player.clubs.map { |c| c['club_id'] }
    assert_equal [@club.id], club_ids
    assert player.clubs.first['home_club'], 'der neue Eintrag ist die Heimatmitgliedschaft'
  end

  test 'TM darf in einem fremden Verein nichts anlegen' do
    fremder = create(:club)
    login_as(create(:user, :tm, team_id: @team.id))

    assert_no_difference 'Player.count' do
      post '/api/v2/admin/players.json',
           params: { id: 0, club_id: fremder.id, first_name: 'Neu', last_name: 'Zugang',
                     birthdate: '2005-03-01', gender: 'w', nation_id: '1' },
           as: :json
    end

    assert_response :forbidden
  end

  # Grenze, die der Anlage gegenübersteht: Wer angelegt ist, wird vom Verband
  # gepflegt (:update_player).
  test 'TM aendert die Stammdaten einer bestehenden Person nicht' do
    login_as(create(:user, :tm, team_id: @team.id))

    post '/api/v2/admin/players.json',
         params: { id: @player.id, club_id: @club.id, first_name: 'Geaendert',
                   last_name: @player.last_name, birthdate: @player.birthdate.to_s },
         as: :json

    assert_response :forbidden
    assert_not_equal 'Geaendert', @player.reload.first_name
  end

  test 'Dublette wird auch dem TM verweigert' do
    login_as(create(:user, :tm, team_id: @team.id))

    assert_no_difference 'Player.count' do
      post '/api/v2/admin/players.json',
           params: { id: 0, club_id: @club.id, first_name: @player.first_name.downcase,
                     last_name: @player.last_name, birthdate: @player.birthdate.to_s,
                     gender: 'm', nation_id: '1' },
           as: :json
    end

    assert_response :unprocessable_entity
  end

  # Regression: Der Rückgabewert von player.save wurde verworfen, die Antwort
  # war auch bei gescheiterter Validierung 201. Die Oberfläche meldete Erfolg
  # und leitete weiter, angelegt war nichts.
  test 'gescheiterte Validierung antwortet 422 statt 201' do
    login_as(create(:user, :tm, team_id: @team.id))

    assert_no_difference 'Player.count' do
      post '/api/v2/admin/players.json',
           params: { id: 0, club_id: @club.id, first_name: 'Neu', last_name: 'Zugang',
                     birthdate: '2005-03-01', gender: 'w', nation_id: '1', email: 'keine-adresse' },
           as: :json
    end

    assert_response :unprocessable_entity
  end

  # params[:id] kam als nil oder als String und brach mit einem 500er ab.
  test 'fehlende id gilt als Anlage statt als Serverfehler' do
    login_as(create(:user, :tm, team_id: @team.id))

    assert_difference 'Player.count', 1 do
      post '/api/v2/admin/players.json',
           params: { club_id: @club.id, first_name: 'Ohne', last_name: 'Id',
                     birthdate: '2005-03-01', gender: 'w', nation_id: '1' },
           as: :json
    end

    assert_response :created
  end

  def create_stats_game(league, team, events)
    arena = create(:arena)
    game_day = GameDay.create!(league: league, arena: arena, club: @club, number: 1, date: '2025-01-01')
    guest = create(:team, league: league, club: @club)
    Game.create!(
      game_day: game_day, home_team: team, guest_team: guest,
      started: true, ended: true, forfait: 0, overtime: false, legacy: false,
      events: events,
      players: { 'home' => [{ 'trikot_number' => 7, 'player_id' => @player.id }], 'guest' => [] }
    )
  end
end
