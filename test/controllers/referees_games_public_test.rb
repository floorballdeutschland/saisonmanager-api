require 'test_helper'

# GET /api/v2/referees/:lizenznummer/games ist laut API-Doku öffentlich (API-Key
# genügt). Bis 1.130.x verlangte der Endpunkt ein Login und lief selbst dann in
# einen Fehler (`includes(:league)` ohne Assoziation).
class RefereesGamesPublicTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze # test/fixtures/api_keys.yml

  setup do
    Rails.cache.clear
    create(:setting, current_season_id: '19')
    Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
    Rails.cache.clear
    @referee = create(:referee, lizenznummer: 710_001, gueltigkeit: Date.new(2027, 9, 30))
    @league = create(:league, season_id: '18')
    @alt = create(:league, season_id: '17')
    @spiel = create(:game, :with_result, game_number: '7',
                                         game_day: create(:game_day, league: @league, date: Date.new(2026, 10, 3)),
                                         officiating_referee_ids: [@referee.id])
    @altspiel = create(:game, game_day: create(:game_day, league: @alt, date: Date.new(2025, 10, 3)),
                              referee_ids: [710_001])
    create(:game, game_day: create(:game_day, league: @league))
  end

  test 'liefert die Spiele mit API-Key ohne Login' do
    get '/api/v2/referees/710001/games', headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal([@spiel.id, @altspiel.id], response.parsed_body.map { |g| g['id'] })
    erstes = response.parsed_body.first
    assert_equal '18', erstes['season_id'].to_s
    assert_equal '2026-10-03', erstes['date']
    assert_equal @league.id, erstes['league_id']
    assert_equal '3:1', erstes['result']
  end

  test 'filtert nach season_id' do
    get '/api/v2/referees/710001/games', params: { season_id: 17 }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal([@altspiel.id], response.parsed_body.map { |g| g['id'] })
  end

  test 'ohne Key und ohne Login 401' do
    get '/api/v2/referees/710001/games'

    assert_response :unauthorized
  end

  test 'Karriere-Beendete antworten wie eine unbekannte Nummer' do
    create(:referee, lizenznummer: 710_002, gueltigkeit: Date.new(2022, 7, 31))

    get '/api/v2/referees/710002/games', headers: { 'X-Api-Key' => API_KEY }

    assert_response :not_found
  end
end
