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
end
