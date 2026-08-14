require 'test_helper'

# Kader-Dialog des Spielberichts am Spielsekretariats-Link: kein Benutzerkonto,
# der Token ist die Berechtigung. Aufstellen durfte das Sekretariat schon
# (GamesController::SECRETARY_ACTIONS), an die Liste der aufstellbaren Personen
# kam es nicht – `user_team_licenses` verlangte einen Login, der 401 warf im
# Frontend den ErrorInterceptor an, und der Zugang war weg.
class ClubsSecretarySquadTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @go = create(:game_operation)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @arena = create(:arena)
    @home_team = create(:team, league: @league, club: @club)
    @guest_team = create(:team, league: @league, club: create(:club))

    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    build_game(@game_day, @home_team, @guest_team)

    # Zweiter Spieltag derselben Liga mit eigenen Mannschaften: außerhalb des Tokens.
    @foreign_team = create(:team, league: @league, club: create(:club))
    foreign_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2, date: '2026-01-17')
    build_game(foreign_day, @foreign_team, create(:team, league: @league, club: create(:club)))

    @player = create(:player,
                     email: 'privat@example.org',
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                     with_licenses: [{ team: @home_team, status: License::APPROVED }])

    _link, @token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))
  end

  test 'Sekretariat bekommt den Kader einer Mannschaft seines Spieltags' do
    get "/api/v2/user/team/#{@home_team.id}/licenses",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    body = JSON.parse(response.body)
    item = body['current_requests'].find { |p| p['id'] == @player.id }
    assert item, 'die lizenzierte Person muss im Kader stehen'
    assert_equal License::APPROVED, item['current_status']['license_status_id']
    assert_equal @home_team.id, body['team']['id']
  end

  test 'der Kader am Token traegt keine personenbezogenen Zusatzdaten' do
    get "/api/v2/user/team/#{@home_team.id}/licenses",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    body = JSON.parse(response.body)
    item = body['current_requests'].sole

    assert_equal %w[birthdate current_status first_name id last_name], item.keys.sort
    assert_not_includes response.body, 'privat@example.org'
    # Lizenzwesen bleibt der angemeldeten Vereinsverwaltung vorbehalten.
    assert_not body.key?('other_players')
    assert_not body.key?('document_types')
    assert_not body.key?('required_documents')
  end

  test 'eine Mannschaft ausserhalb der abgedeckten Spieltage bleibt gesperrt' do
    get "/api/v2/user/team/#{@foreign_team.id}/licenses",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :forbidden
  end

  test 'ohne Token und ohne Login bleibt der Kader gesperrt' do
    get "/api/v2/user/team/#{@home_team.id}/licenses", headers: { 'X-Api-Key' => API_KEY }

    assert_response :unauthorized
  end

  test 'ein abgelaufener Token wird als solcher gemeldet' do
    GameDaySecretaryLink.find_by_token(@token).update!(expires_at: 1.hour.ago)

    get "/api/v2/user/team/#{@home_team.id}/licenses",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :unauthorized
    assert_match(/Spielsekretariats-Link/, JSON.parse(response.body)['message'])
  end

  # Wer angemeldet ist, bekommt weiter das vollständige Team-Lizenzwesen, auch
  # wenn im selben Browser noch ein Token liegt (der Interceptor hängt ihn an
  # jede Anfrage).
  test 'der angemeldete VM behaelt das vollstaendige Lizenzwesen' do
    user = create(:user, :vm, club_id: @club.id)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success

    get "/api/v2/user/team/#{@home_team.id}/licenses",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    body = JSON.parse(response.body)
    assert body.key?('other_players')
    assert body.key?('document_types')
    assert_includes body['current_requests'].sole.keys, 'can_withdraw'
  end

  # Der Interceptor hängt einen im sessionStorage liegenden Token an jede
  # Anfrage. Würde der Endpunkt einen Token erzwingen, holte sich eine
  # angemeldete Person mit einem veralteten Token einen 401 ab, und der
  # ErrorInterceptor meldete sie ab.
  test 'ein veralteter Token nimmt dem angemeldeten VM nichts' do
    user = create(:user, :vm, club_id: @club.id)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success

    get "/api/v2/user/team/#{@home_team.id}/licenses",
        params: { secretary_token: 'laengst-abgelaufen' }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert JSON.parse(response.body).key?('other_players')
  end

  private

  def build_game(game_day, home_team, guest_team)
    Game.create!(
      game_day: game_day,
      home_team: home_team,
      guest_team: guest_team,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
  end
end
