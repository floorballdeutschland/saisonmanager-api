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
    @link, @token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # `via: :header` schickt den Token so, wie der SecretaryTokenInterceptor es tut
  # (`setHeaders: { 'X-Secretary-Token': token }`). Der Parameter-Weg ist der
  # bequemere im Test, aber im Betrieb kommt der Token ausschließlich als Header.
  def set_field(game, token: nil, value: 'Meier, Anna', via: :param)
    params = { game: { record_keeper_string: value } }
    headers = { 'X-Api-Key' => API_KEY }
    if token
      via == :header ? headers['X-Secretary-Token'] = token : params[:secretary_token] = token
    end
    post "/api/v2/user/games/#{game.id}/set_field", params: params, headers: headers
  end

  # --- 1. Der abgelaufene Link darf die Sitzung nicht wegwerfen ---------------

  # Der echte Ablauf, nicht bloß ein erfundener Token: `find_by_token` sucht im
  # `active`-Scope, nach 72 Stunden (`VALIDITY`) gibt es also nil. Damit schlägt
  # der Test auch an, wenn jemand den Scope aus `find_by_token` entfernt.
  test 'angemeldet mit abgelaufenem Link bleibt der Schreibweg offen' do
    @link.update!(expires_at: 1.hour.ago)
    login_as(@vm)

    set_field(@game, token: @token)

    assert_response :success
    assert_equal 'Meier, Anna', @game.reload.record_keeper_string
  end

  # Über den Header, also auf dem Weg, den das Frontend tatsächlich benutzt.
  test 'angemeldet mit unbrauchbarem Token im Header bleibt der Schreibweg offen' do
    login_as(@vm)

    set_field(@game, token: 'abgelaufen-oder-geloescht', via: :header)

    assert_response :success
    assert_equal 'Meier, Anna', @game.reload.record_keeper_string
  end

  test 'angemeldet mit unbrauchbarem Token bleibt der Schreibweg offen' do
    login_as(@vm)

    set_field(@game, token: 'abgelaufen-oder-geloescht')

    assert_response :success
    assert_equal 'Meier, Anna', @game.reload.record_keeper_string
  end

  # Die neue Nutzererfahrung, wenn beide Wege versagen: Der Link ist tot, die
  # Rolle trägt dieses Spiel nicht. Vorher gab es 401 mit der Link-Meldung (und
  # eine Abmeldung mitten im Spiel), jetzt eine gewöhnliche Rechte-Absage.
  test 'toter Link plus nicht tragende Rolle ergibt eine Rechte-Absage, keine Abmeldung' do
    @link.update!(expires_at: 1.hour.ago)
    fremdes_team = create(:team, league: @league, club: create(:club))
    login_as(create(:user, :tm, team_id: fremdes_team.id))

    set_field(@game, token: @token, via: :header)

    assert_response :forbidden
    assert_nil @game.reload.record_keeper_string
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
  # dahinter richtete sich nach dem Link. Hier trägt allein der Link, die Rolle
  # steuert nichts bei.
  test 'Spielseite liefert die Rechte des Links auch an eine angemeldete Person' do
    fremdes_team = create(:team, league: @league, club: create(:club))
    ohne_rechte = create(:user, :tm, team_id: fremdes_team.id)
    login_as(ohne_rechte)

    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: @token },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    perms = JSON.parse(response.body)['permission']
    assert_includes perms, 'edit_game_report', 'die Rechte des Links fehlen, obwohl er dieses Spiel abdeckt'
    # Der Link bleibt auf SECRETARY_PERMISSIONS begrenzt, auch wenn ein Admin ihn
    # erzeugt hat. Gegenprobe zum token-only-Zwilling in games_secretary_view_test.
    assert_not_includes perms, 'check_game'
    assert_not_includes perms, 'edit_game'
    assert_not_includes perms, 'edit_referee_nomination'
  end

  # Der eigentliche Vereinigungsfall: Beide Seiten steuern etwas bei, und die
  # Mengen überschneiden sich nur teilweise. Ein `Array(...)` ohne `|` käme hier
  # nicht durch, und Doppelungen fielen ebenfalls auf.
  test 'Spielseite vereinigt die Rechte aus Rolle und Link ohne Doppelung' do
    sbk = create(:user, :sbk_scoped, game_operation_id: @go.id)
    login_as(sbk)

    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: @token },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    perms = JSON.parse(response.body)['permission']
    assert_includes perms, 'edit_referee_nomination', 'die Rechte der Rolle fehlen'
    assert_includes perms, 'edit_game_report', 'die Rechte des Links fehlen'
    assert_equal perms.uniq, perms, 'die Vereinigung dedupliziert nicht'
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

  # Die Checkliste ist ein internes Feld und folgt derselben Grenze wie die
  # Bedienelemente: Ein Link für eine andere Halle zeigt sie nicht, obwohl er
  # gültig ist und der Interceptor ihn mitschickt.
  test 'ein fremder Hallenlink zeigt die Checkliste nicht' do
    @sa.checklist_items.create!(question: 'Halle bespielbar?', position: 1)

    get "/api/v2/games/#{@foreign_game.id}.json", params: { secretary_token: @token },
                                                  headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_nil JSON.parse(response.body)['checklist_items']

    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: @token },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal(['Halle bespielbar?'], JSON.parse(response.body)['checklist_items'].map { |i| i['question'] })
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

  # Wer angemeldet ist, steht als Urheber in der Historie, auch wenn er kraft
  # Link schreibt und nicht kraft Rolle. `show` gibt den Namen an Admin und SBK
  # als `record_updated_by_name` aus, das ist also sichtbares Verhalten.
  test 'die angemeldete Person ist Urheberin, nicht der Aussteller des Links' do
    fremdes_team = create(:team, league: @league, club: create(:club))
    ohne_rechte = create(:user, :tm, team_id: fremdes_team.id)
    login_as(ohne_rechte)

    set_field(@game, token: @token, via: :header)

    assert_response :success
    assert_equal ohne_rechte.id, @game.reload.record_updated_by
  end

  # --- 3. Die Sperre für abgeschlossene Berichte -------------------------------
  #
  # Die einzige Stelle, an der die Additivität eine echte Sperre berührt:
  # `add_event` verlangt vor `can_edit_game?` zusätzlich `admin_or_scoped_sbk?`,
  # und das liest allein `current_user`. Eine angemeldete SBK mit einem nicht
  # deckenden Token kam vorher gar nicht so weit, sie scheiterte schon am Token.

  def add_event(game, token:, user_login:)
    login_as(user_login)
    post "/api/v2/user/games/#{game.id}/events/add",
         params: { event_type: 'goal', event_team: 'home', period: 1, time: '10:00' },
         headers: { 'X-Api-Key' => API_KEY, 'X-Secretary-Token' => token }
  end

  # Der Token deckt @game ab, nicht @foreign_game. Die SBK arbeitet hier also am
  # abgeschlossenen Bericht eines Spiels, für das ihr Token nichts hergibt.
  test 'angemeldete SBK uebergeht die Abschluss-Sperre auch mit fremdem Token' do
    @foreign_game.update!(game_status: 'match_record_closed')
    sbk = create(:user, :sbk_scoped, game_operation_id: @go.id)

    add_event(@foreign_game, token: @token, user_login: sbk)

    assert_response :success
    assert_equal 1, @foreign_game.reload.events.size
  end

  # Gegenprobe: Der Token hebelt die Sperre nicht aus, auch nicht dort, wo er
  # gilt und die Rolle das Spiel ohnehin trägt.
  test 'VM uebergeht die Abschluss-Sperre auch mit deckendem Token nicht' do
    @game.update!(game_status: 'match_record_closed')

    add_event(@game, token: @token, user_login: @vm)

    assert_response :forbidden
    assert_empty @game.reload.events
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
