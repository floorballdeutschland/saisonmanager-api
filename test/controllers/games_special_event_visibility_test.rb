require 'test_helper'

# Der Vermerk über ein besonderes Ereignis ist ein interner Teil des
# Spielberichts: Er nennt regelmäßig Namen und beschreibt das Verhalten
# einzelner Personen. Die öffentliche Spieldetailseite zeigte ihn bisher jedem,
# auch anonym und über den API-Schlüssel, danach (#679) jedem Login. Jetzt sieht
# ihn nur, wer den Spielbericht pflegt, dazu die RSK des Spielbetriebs.
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

  test 'ein Login ohne Bezug zum Spiel sieht den Vermerk nicht' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    assert_not response.parsed_body.key?('special_event_string')
    assert_not_includes response.body, VERMERK
  end

  test 'Vereinsmanager eines fremden Vereins sieht den Vermerk nicht' do
    login(create(:user, :vm, club_id: create(:club, state_association_id: @sa.id).id))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    assert_not_includes response.body, VERMERK
  end

  test 'Teammanager einer unbeteiligten Mannschaft sieht den Vermerk nicht' do
    other = create(:team, league: @league, club: create(:club, state_association_id: @sa.id))
    login(create(:user, :tm, team_id: other.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    assert_not_includes response.body, VERMERK
  end

  test 'SBK des Spielbetriebs sieht den Vermerk' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_equal VERMERK, response.parsed_body['special_event_string']
  end

  test 'Vereinsmanager eines beteiligten Vereins sieht den Vermerk' do
    guest_club = create(:club, state_association_id: @sa.id)
    @guest.update!(club: guest_club)
    login(create(:user, :vm, club_id: guest_club.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_equal VERMERK, response.parsed_body['special_event_string']
  end

  test 'Teammanager einer beteiligten Mannschaft sieht den Vermerk' do
    login(create(:user, :tm, team_id: @guest.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_equal VERMERK, response.parsed_body['special_event_string']
  end

  test 'RSK des Spielbetriebs sieht den Vermerk' do
    login(create(:user, :rsk_scoped, game_operation_id: @go.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_equal VERMERK, response.parsed_body['special_event_string']
  end

  test 'RSK eines fremden Spielbetriebs sieht den Vermerk nicht' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :rsk_scoped, game_operation_id: other_go.id))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    assert_not_includes response.body, VERMERK
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
