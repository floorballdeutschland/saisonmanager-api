require 'test_helper'

# Login und Spielsekretariats-Token zugleich (#428).
#
# Der SecretaryTokenInterceptor im Frontend hängt einen einmal im sessionStorage
# abgelegten Token an JEDE Anfrage und löscht ihn nirgends. Wer in einer
# Registerkarte einmal einen Sekretariats-Link geöffnet hat, trägt ihn dort
# dauerhaft mit, auch nach einer normalen Anmeldung. Zwei Folgen hatte das:
#
#   1. Ein unbrauchbarer Token warf die Sitzung weg: `authenticate_with_secretary_token_or_user`
#      prüfte zuerst den Token und antwortete 401, unabhängig von current_user.
#      Nach Ablauf des Links (72 Stunden) traf das jeden Schreibweg des
#      Spielberichts.
#   2. Ein gültiger Token verdrängte die eigenen Rechte: can_edit_game? und
#      can_view_hidden_elements? kehrten bei gesetztem @secretary_link sofort
#      zurück und kamen nie zur Rollenprüfung.
class GamesSecretaryTokenLoginTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)

    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @game = build_game(@game_day)

    # Zweiter Spieltag derselben Liga: außerhalb des Token-Scopes.
    other_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2, date: '2026-01-17')
    @foreign_game = build_game(other_day)

    @vm = create(:user, :vm, club_id: @club.id)
    _link, @token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def set_field(game, token: nil, value: 'Meier, Anna')
    params = { game: { record_keeper_string: value } }
    params[:secretary_token] = token if token
    post "/api/v2/user/games/#{game.id}/set_field", params: params, headers: { 'X-Api-Key' => API_KEY }
  end

  # --- 1. Der abgelaufene Link darf die Sitzung nicht wegwerfen ---------------

  test 'angemeldet mit unbrauchbarem Token bleibt der Schreibweg offen' do
    login_as(@vm)

    set_field(@game, token: 'abgelaufen-oder-geloescht')

    assert_response :success
    assert_equal 'Meier, Anna', @game.reload.record_keeper_string
  end

  test 'ohne Login weist ein unbrauchbarer Token weiterhin ab' do
    set_field(@game, token: 'abgelaufen-oder-geloescht')

    assert_response :unauthorized
    assert_match(/Spielsekretariats-Link/, JSON.parse(response.body)['message'])
  end

  test 'ohne Login und ohne Token bleibt es bei Not authenticated' do
    set_field(@game)

    assert_response :unauthorized
    assert_equal 'Not authenticated', JSON.parse(response.body)['message']
  end

  # --- 2. Der gültige Link darf die eigene Rolle nicht verdrängen -------------

  test 'ein gueltiger Token nimmt der Rolle nicht die Spiele ausserhalb seines Scopes' do
    login_as(@vm)

    set_field(@foreign_game, token: @token, value: 'Ziegler, Bo')

    assert_response :success
    assert_equal 'Ziegler, Bo', @foreign_game.reload.record_keeper_string
  end

  test 'interne Felder eines fremden Spieltags bleiben der Rolle erhalten' do
    @foreign_game.update!(special_event_string: 'Interner Vermerk')
    login_as(@vm)

    get "/api/v2/user/games/#{@foreign_game.id}/additional_fields.json",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal 'Interner Vermerk', JSON.parse(response.body)['special_event_string']
  end

  # Die Oberfläche zeigte die Bedienelemente der eigenen Rolle, der Schreibweg
  # dahinter richtete sich nach dem Link. Beide Seiten rechnen jetzt additiv.
  test 'Spielseite vereinigt die Rechte aus Rolle und Link' do
    fremdes_team = create(:team, league: @league, club: create(:club))
    ohne_rechte = create(:user, :tm, team_id: fremdes_team.id)
    login_as(ohne_rechte)

    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: @token },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_includes JSON.parse(response.body)['permission'], 'edit_game_report',
                    'die Rechte des Links fehlen, obwohl er dieses Spiel abdeckt'
  end

  test 'Spielseite behaelt die Rechte der Rolle bei einem fremden Spieltag' do
    login_as(@vm)

    get "/api/v2/games/#{@foreign_game.id}.json", params: { secretary_token: @token },
                                                  headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    perms = JSON.parse(response.body)['permission']
    assert_includes perms, 'edit_game_report'
    assert_includes perms, 'pregame_edit_home'
  end

  # Gegenprobe: Der Token allein trägt weiter, und nur so weit wie sein Scope.
  test 'der Token allein bearbeitet sein Spiel und nur seines' do
    set_field(@game, token: @token, value: 'Nur Token')
    assert_response :success
    assert_equal 'Nur Token', @game.reload.record_keeper_string

    set_field(@foreign_game, token: @token, value: 'Nicht abgedeckt')
    assert_response :forbidden
    assert_nil @foreign_game.reload.record_keeper_string
  end

  private

  def build_game(game_day)
    Game.create!(
      game_day: game_day,
      home_team: create(:team, league: @league, club: @club),
      guest_team: create(:team, league: @league, club: @club),
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
  end
end
