require 'test_helper'

# Der Vermerk über ein besonderes Ereignis ist ein interner Teil des
# Spielberichts: Er nennt regelmäßig Namen und beschreibt das Verhalten
# einzelner Personen. Die öffentliche Spieldetailseite zeigte ihn bisher jedem,
# auch anonym und über den API-Schlüssel. Jetzt gibt es ihn nur noch mit Login
# (oder Sekretariats-Link).
class GamesSpecialEventVisibilityTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze # test/fixtures/api_keys.yml
  VERMERK = 'Zuschauer X hat den Schiedsrichter beleidigt'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(
      game_day: @game_day, home_team: @home, guest_team: @guest,
      started: true, ended: true, forfait: 0, overtime: false, legacy: false,
      events: [], players: { 'home' => [], 'guest' => [] },
      special_event_string: VERMERK
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  test 'anonymer Abruf der Spielseite liefert den Vermerk nicht' do
    get "/api/v2/games/#{@game.id}.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_not response.parsed_body.key?('special_event_string')
    # Zweite Klammer: Der Text darf auch über kein anderes Feld herausfallen.
    assert_not_includes response.body, VERMERK
  end

  test 'angemeldeter Abruf liefert den Vermerk weiterhin' do
    login(create(:user, :admin))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    assert_equal VERMERK, response.parsed_body['special_event_string']
  end

  # Bewusst jeder Login, nicht nur die Rollen aus can_view_hidden_elements?:
  # Eingeschränkt wird hier die Öffentlichkeit, nicht der angemeldete Betrieb.
  test 'auch ein Login ohne Bezug zum Spiel sieht den Vermerk' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    assert_equal VERMERK, response.parsed_body['special_event_string']
  end

  test 'das Spielsekretariat sieht den Vermerk über seinen Link' do
    _link, token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))

    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: token },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal VERMERK, response.parsed_body['special_event_string']
  end

  # Der anonyme Zweig von GamesController#show legt den Hash in den Cache. Ein
  # Treffer darf den Vermerk genauso wenig enthalten wie ein Neuaufbau.
  test 'auch die zwischengespeicherte Antwort bleibt ohne den Vermerk' do
    with_real_cache do
      2.times do
        get "/api/v2/games/#{@game.id}.json", headers: { 'X-Api-Key' => API_KEY }

        assert_response :success
        assert_not_includes response.body, VERMERK
      end
    end
  end
end
