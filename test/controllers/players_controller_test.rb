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

  # global_search (Spielersuche /verwaltung/spieler/suche): deaktivierte Spieler
  # (z.B. per Duplikat-Merge zusammengeführte Profile) dürfen nicht erscheinen.
  test 'global_search findet aktive Spieler, aber keine deaktivierten' do
    admin = create(:user, :admin)
    active = create(:player, first_name: 'Aktiv', last_name: 'Suchbar')
    deactivated = create(:player, first_name: 'Deaktiv', last_name: 'Suchbar')
    deactivated.deactivate!(admin.id, reason: 'Zusammenführung')

    login_as(admin)
    get '/api/v2/admin/players/search', params: { q: 'Suchbar' }

    assert_response :success
    ids = JSON.parse(response.body).map { |p| p['id'] }
    assert_includes ids, active.id
    assert_not_includes ids, deactivated.id
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

  private

  # Beendetes Spiel mit @player (Trikot 7) in der Heim-Aufstellung.
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
