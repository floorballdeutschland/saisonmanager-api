require 'test_helper'

# Smoke-Test der OpenAPI-Foundation (PR „feat/openapi-foundation").
#
# Zweck: nachweisen, dass committee-rails die Response gegen das
# Schema aus docs/openapi/openapi.yml validiert. Inhaltliche Endpoint-
# Tests folgen in Phase 2 (Issue #174) auf FactoryBot-Basis.
class LeaguesControllerTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    @go = GameOperation.create!(name: 'Test GO', short_name: 'TGO')
    @league = League.create!(
      game_operation: @go,
      name: 'Testliga',
      season_id: '1',
      table_modus: 'classic'
    )
    @club = Club.create!
    @arena = Arena.create!(name: 'Testhalle', city: 'Teststadt')
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2025-01-01')
    @home = Team.create!(league: @league, club: @club, name: 'Heim')
    @guest = Team.create!(league: @league, club: @club, name: 'Gast')
    Game.create!(
      game_day: @game_day,
      home_team: @home,
      guest_team: @guest,
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [{ 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 }],
      players: { 'home' => [], 'guest' => [] }
    )
    Rails.cache.clear
  end

  test 'GET /leagues/:id/schedule – ohne Auth ergibt 401 mit ErrorResponse-Schema' do
    get "/api/v2/leagues/#{@league.id}/schedule"
    assert_response :unauthorized
    assert_schema_conform 401
  end

  test 'GET /leagues/:id/schedule – mit X-Api-Key liefert Schedule, Schema valide' do
    get "/api/v2/leagues/#{@league.id}/schedule", headers: { 'X-Api-Key' => API_KEY }
    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body
    assert_equal 1, body.size
    assert_schema_conform 200
  end

  test 'GET /leagues/:id/table – mit X-Api-Key liefert Tabelle, Schema valide' do
    get "/api/v2/leagues/#{@league.id}/table", headers: { 'X-Api-Key' => API_KEY }
    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body
    assert_schema_conform 200
  end

  test 'GET /leagues/:id/scorer – mit X-Api-Key liefert Scorer, Schema valide' do
    get "/api/v2/leagues/#{@league.id}/scorer", headers: { 'X-Api-Key' => API_KEY }
    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body
    assert_schema_conform 200
  end

  # --- copy_preround_licenses (Phase 2) ---

  test 'copy_preround_licenses: Admin mit Berechtigung kopiert genehmigte Lizenzen und gibt {copied: N} zurück' do
    go = GameOperation.create!(name: 'GO CopyTest', short_name: 'GCT')
    club = Club.create!(name: 'Kopier-Club', short_name: 'KC')

    preround_league = League.create!(
      game_operation: go, name: 'Vorrunde', season_id: '17', table_modus: 'classic'
    )
    final_league = League.create!(
      game_operation: go, name: 'Finalrunde', season_id: '18', table_modus: 'classic',
      league_id_preround: preround_league.id
    )

    preround_team = Team.create!(league: preround_league, club: club, name: 'VR Team')
    Team.create!(league: final_league, club: club, name: 'Finale Team')

    player = create(:player, with_licenses: [{ team: preround_team, status: License::APPROVED }])

    admin = User.create!(
      user_name: "admin_cpl_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
      teams: []
    )

    post '/api/v2/login', params: { username: admin.user_name, password: 'password123' }
    assert_response :success

    post "/api/v2/admin/leagues/#{final_league.id}/copy_preround_licenses"
    assert_response :success

    body = JSON.parse(response.body)
    assert_equal 1, body['copied']

    player.reload
    final_team = final_league.teams.find_by(club: club)
    copied = player.licenses.find { |l| l['team_id'].to_i == final_team.id }
    assert_not_nil copied
    assert_equal License::APPROVED,
                 copied['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
  end

  test 'copy_preround_licenses: Liga ohne league_id_preround gibt 422 zurück' do
    go = GameOperation.create!(name: 'GO NoPre', short_name: 'GNP')
    league_no_pre = League.create!(
      game_operation: go, name: 'Ohne Vorrunde', season_id: '18', table_modus: 'classic'
    )

    admin = User.create!(
      user_name: "admin_nopre_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
      teams: []
    )

    post '/api/v2/login', params: { username: admin.user_name, password: 'password123' }
    assert_response :success

    post "/api/v2/admin/leagues/#{league_no_pre.id}/copy_preround_licenses"
    assert_response :unprocessable_entity
  end

  test 'copy_preround_licenses: Nicht-Admin-Benutzer erhält 403' do
    go = GameOperation.create!(name: 'GO Unauth', short_name: 'GUA')
    league_with_pre = League.create!(
      game_operation: go, name: 'Liga mit Pre', season_id: '18', table_modus: 'classic',
      league_id_preround: 9999
    )

    vm_user = User.create!(
      user_name: "vm_cpl_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => 1 }],
      teams: []
    )

    post '/api/v2/login', params: { username: vm_user.user_name, password: 'password123' }
    assert_response :success

    post "/api/v2/admin/leagues/#{league_with_pre.id}/copy_preround_licenses"
    assert_response :forbidden
  end

  # --- admin_league_update: Ligaklassen-Validierung (#297) ---

  test 'admin_league_update: unbekannte Ligaklasse beim Anlegen ergibt 422 mit message statt stillem 201' do
    # Settings-Fixture liefert kein brauchbares current_season_id — Factory ersetzt sie.
    create(:setting)
    go = GameOperation.create!(name: 'GO KlasseTest', short_name: 'GKT')
    admin = User.create!(
      user_name: "admin_lcl_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
      teams: []
    )

    post '/api/v2/login', params: { username: admin.user_name, password: 'password123' }
    assert_response :success

    post '/api/v2/admin/leagues',
         params: { id: 0, game_operation_id: go.id,
                   league: { game_operation_id: go.id, name: 'Oberliga Nord',
                             league_class_id: 'oberliga', table_modus: 'classic' } },
         as: :json
    assert_response :unprocessable_entity
    assert JSON.parse(response.body)['message'].present?, '422-Body braucht message-Key (ErrorInterceptor)'
    assert_equal 0, League.where(name: 'Oberliga Nord').count
  end

  test 'admin_league_update: gültiger Ligaklassen-Code wird angelegt (201)' do
    create(:setting)
    go = GameOperation.create!(name: 'GO KlasseOk', short_name: 'GKO')
    admin = User.create!(
      user_name: "admin_lcl_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
      teams: []
    )

    post '/api/v2/login', params: { username: admin.user_name, password: 'password123' }
    assert_response :success

    post '/api/v2/admin/leagues',
         params: { id: 0, game_operation_id: go.id,
                   league: { game_operation_id: go.id, name: 'Verbandsliga Test',
                             league_class_id: 'vl', table_modus: 'classic' } },
         as: :json
    assert_response :created
    assert_equal 'vl', League.find_by(name: 'Verbandsliga Test').league_class_id
  end

  test 'admin_league_team_index erlaubt dem SBK des Spielbetriebs den Zugriff' do
    create(:setting)
    sa = create(:state_association)
    scoped_go = create(:game_operation, state_association_id: sa.id)
    league = create(:league, game_operation: scoped_go)
    login_as(create(:user, :sbk_scoped, game_operation_id: scoped_go.id))

    get "/api/v2/admin/leagues/#{league.id}/teams"

    assert_response :success
  end

  test 'admin_league_team_index sperrt SBK eines fremden Spielbetriebs' do
    create(:setting)
    sa = create(:state_association)
    scoped_go = create(:game_operation, state_association_id: sa.id)
    league = create(:league, game_operation: scoped_go)
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/admin/leagues/#{league.id}/teams"

    assert_response :forbidden
  end

  test 'admin_game_schedule sperrt SBK eines fremden Spielbetriebs' do
    create(:setting)
    sa = create(:state_association)
    scoped_go = create(:game_operation, state_association_id: sa.id)
    league = create(:league, game_operation: scoped_go)
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login_as(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/admin/leagues/#{league.id}/game_schedule"

    assert_response :forbidden
  end

  test 'admin_game_schedule erlaubt dem globalen Admin den Zugriff' do
    create(:setting)
    league = create(:league)
    login_as(create(:user, :admin))

    get "/api/v2/admin/leagues/#{league.id}/game_schedule"

    assert_response :success
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
  private :login_as

  # --- admin_copy: Liga aus Vorsaison kopieren (#69) ---

  def create_copy_source_league(operation)
    create(:league, :previous_season, game_operation: operation,
                                      name: 'Verbandsliga Nord', short_name: 'VL N',
                                      league_class_id: 'vl', league_category_id: '1',
                                      league_system_id: '2', league_type: 'league',
                                      league_modus: 'double', table_modus: 'classic',
                                      has_preround: true, female: true, enable_scorer: true,
                                      field_size: 'GF', periods: 3, period_length: 20,
                                      overtime_length: 10, order_key: '5',
                                      deadline: Date.new(2025, 7, 31), before_deadline: true,
                                      referee_feedback_enabled: true)
  end
  private :create_copy_source_league

  test 'admin_copy: Admin kopiert Stammdaten in die aktuelle Saison – ohne Spieltage und Teams' do
    create(:setting) # current_season_id 18
    go = create(:game_operation)
    source = create_copy_source_league(go)
    club = create(:club)
    GameDay.create!(league: source, arena: create(:arena), club: club, number: 1, date: '2025-01-01')
    create(:team, league: source, club: club)

    login_as create(:user, :admin)

    post "/api/v2/admin/leagues/#{source.id}/copy", as: :json
    assert_response :created

    copy = League.find(JSON.parse(response.body)['id'])
    assert_equal '18', copy.season_id
    assert_equal Date.new(2026, 7, 31), copy.deadline, 'deadline muss um +1 Jahr verschoben werden'
    assert_equal source.id, copy.league_id_preseason
    assert_not copy.legacy_league

    %w[game_operation_id name short_name league_category_id league_class_id league_system_id
       league_type league_modus table_modus has_preround female enable_scorer field_size
       periods period_length overtime_length order_key before_deadline
       referee_feedback_enabled].each do |attr|
      assert_equal source[attr], copy[attr], "Attribut #{attr} muss kopiert werden"
    end

    assert_equal 0, copy.game_days.count, 'Spieltage dürfen nicht kopiert werden'
    assert_equal 0, Team.where(league_id: copy.id).count, 'ohne include_teams keine Teams'
  end

  test 'admin_copy: include_teams kopiert Teams mit approved=false; nil-deadline bleibt nil' do
    create(:setting)
    go = create(:game_operation)
    source = create(:league, :previous_season, game_operation: go, deadline: nil)
    club = create(:club)
    Team.create!(league: source, club: club, name: 'Team Alt', short_name: 'ALT',
                 syndicate: true, syndicate_clubs: [club.id], approved: true,
                 contact_person: 'Max Muster', contact_email: 'max@example.org')

    login_as create(:user, :admin)

    post "/api/v2/admin/leagues/#{source.id}/copy", params: { include_teams: true }, as: :json
    assert_response :created

    copy = League.find(JSON.parse(response.body)['id'])
    assert_nil copy.deadline

    copied_team = Team.find_by(league_id: copy.id)
    assert_not_nil copied_team
    assert_not copied_team.approved, 'kopierte Teams müssen neu bestätigt werden (approved=false)'
    assert_equal club.id, copied_team.club_id
    assert_equal 'Team Alt', copied_team.name
    assert_equal 'ALT', copied_team.short_name
    assert copied_team.syndicate
    assert_equal [club.id], copied_team.syndicate_clubs
    assert_equal 'Max Muster', copied_team.contact_person
    assert_equal 'max@example.org', copied_team.contact_email
  end

  test 'admin_copy: team_ids kopiert nur die ausgewählten Teams' do
    create(:setting)
    go = create(:game_operation)
    source = create(:league, :previous_season, game_operation: go)
    club = create(:club)
    keep = Team.create!(league: source, club: club, name: 'Bleibt', short_name: 'BLB', approved: true)
    Team.create!(league: source, club: club, name: 'Fliegt raus', short_name: 'RAUS', approved: true)

    login_as create(:user, :admin)

    post "/api/v2/admin/leagues/#{source.id}/copy", params: { team_ids: [keep.id] }, as: :json
    assert_response :created

    copy = League.find(JSON.parse(response.body)['id'])
    copied = Team.where(league_id: copy.id)
    assert_equal 1, copied.count, 'nur das ausgewählte Team darf kopiert werden'
    assert_equal 'Bleibt', copied.first.name
    assert_not copied.first.approved
  end

  test 'admin_copy: leere team_ids kopiert nur die Liga ohne Teams' do
    create(:setting)
    go = create(:game_operation)
    source = create(:league, :previous_season, game_operation: go)
    create(:team, league: source, club: create(:club))

    login_as create(:user, :admin)

    post "/api/v2/admin/leagues/#{source.id}/copy", params: { team_ids: [] }, as: :json
    assert_response :created

    copy = League.find(JSON.parse(response.body)['id'])
    assert_equal 0, Team.where(league_id: copy.id).count, 'leere Auswahl darf keine Teams kopieren'
  end

  test 'admin_copy: team_ids ignoriert Team-IDs fremder Ligen' do
    create(:setting)
    go = create(:game_operation)
    source = create(:league, :previous_season, game_operation: go)
    other = create(:league, :previous_season, game_operation: go)
    foreign = create(:team, league: other, club: create(:club))

    login_as create(:user, :admin)

    post "/api/v2/admin/leagues/#{source.id}/copy", params: { team_ids: [foreign.id] }, as: :json
    assert_response :created

    copy = League.find(JSON.parse(response.body)['id'])
    assert_equal 0, Team.where(league_id: copy.id).count, 'fremde Team-IDs dürfen nicht kopiert werden'
  end

  test 'admin_copy: un-normalisierte league_class_id der Quelle wird beim Kopieren normalisiert (#114)' do
    create(:setting)
    go = create(:game_operation)
    source = create(:league, :previous_season, game_operation: go,
                                                name: '1. FBL Damen', league_class_id: 'vl')
    # Legacy-/Import-Wert an der Validierung vorbei setzen, wie im Prod-Bestand.
    source.update_columns(league_class_id: '10')

    login_as create(:user, :admin)

    post "/api/v2/admin/leagues/#{source.id}/copy", as: :json
    assert_response :created, 'Kopie darf nicht an der Ligaklassen-Validierung scheitern'

    copy = League.find(JSON.parse(response.body)['id'])
    assert_equal '1fbl', copy.league_class_id, '"1. FBL Damen" muss auf 1fbl normalisiert werden'
  end

  test 'admin_copy: Buli-Check greift auf den normalisierten Wert (Legacy "10" => 1fbl)' do
    create(:setting)
    go = create(:game_operation, state_association: create(:state_association))
    source = create(:league, :previous_season, game_operation: go,
                                                name: '1. FBL Damen', league_class_id: 'vl')
    source.update_columns(league_class_id: '10')

    # SBK ohne Buli-Berechtigung darf eine (normalisiert) 1fbl-Liga nicht kopieren.
    login_as create(:user, :sbk_scoped, game_operation_id: go.id)

    post "/api/v2/admin/leagues/#{source.id}/copy", as: :json
    assert_response :forbidden
    assert_equal 1, League.where(game_operation_id: go.id).count, 'es darf keine Kopie entstehen'
  end

  test 'admin_copy: SBK des eigenen Verbands darf kopieren' do
    create(:setting)
    go = create(:game_operation, state_association: create(:state_association))
    source = create(:league, :previous_season, game_operation: go, league_class_id: 'vl')

    login_as create(:user, :sbk_scoped, game_operation_id: go.id)

    post "/api/v2/admin/leagues/#{source.id}/copy", as: :json
    assert_response :created
  end

  test 'admin_copy: SBK eines anderen Verbands erhält 403' do
    create(:setting)
    go = create(:game_operation, state_association: create(:state_association))
    other_go = create(:game_operation, state_association: create(:state_association))
    source = create(:league, :previous_season, game_operation: go, league_class_id: 'vl')

    login_as create(:user, :sbk_scoped, game_operation_id: other_go.id)

    post "/api/v2/admin/leagues/#{source.id}/copy", as: :json
    assert_response :forbidden
    assert_equal 1, League.where(game_operation_id: go.id).count, 'es darf keine Kopie entstehen'
  end

  test 'admin_copy: Vereinsmanager erhält 403' do
    create(:setting)
    go = create(:game_operation)
    source = create(:league, :previous_season, game_operation: go, league_class_id: 'vl')

    login_as create(:user, :vm, club_id: 1)

    post "/api/v2/admin/leagues/#{source.id}/copy", as: :json
    assert_response :forbidden
  end
end
