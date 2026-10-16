require 'test_helper'

# Die API-Doku nennt GET /api/v2/game_operations und
# GET /api/v2/game_operations/by_shortname/:name. Bis 1.130.x gab es beide nur
# ohne den api/v2-Praefix, von aussen also 404.
class GameOperationsPublicTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze # test/fixtures/api_keys.yml

  setup do
    create(:setting)
    @go = create(:game_operation, path: 'ost', short_name: 'SBK Ost')
  end

  test 'Liste unter api/v2' do
    get '/api/v2/game_operations', headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_includes(response.parsed_body.map { |g| g['id'] }, @go.id)
    eintrag = response.parsed_body.find { |g| g['id'] == @go.id }
    assert_equal 'ost', eintrag['path']
    assert_not eintrag.key?('national'), 'national gehoert nicht in oeffentliche Antworten'
    assert_not eintrag.key?('created_at')
  end

  test 'Liste ohne Key 401' do
    get '/api/v2/game_operations'

    assert_response :unauthorized
  end

  test 'Kurzname unter api/v2 findet ueber path' do
    get '/api/v2/game_operations/by_shortname/ost', headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal @go.id, response.parsed_body['id']
    assert_not response.parsed_body.key?('national')
  end

  test 'unbekannter Kurzname 404 statt null' do
    get '/api/v2/game_operations/by_shortname/gibtsnicht', headers: { 'X-Api-Key' => API_KEY }

    assert_response :not_found
  end
end
