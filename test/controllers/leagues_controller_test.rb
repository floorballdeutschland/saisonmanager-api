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
end
