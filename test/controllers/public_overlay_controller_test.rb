require 'test_helper'

# Datenquelle der Livestream-Overlays. Der Zugang läuft allein über das
# Spieltags-Token und hebt dabei die Zehn-Minuten-Verzögerung auf, die für
# API-Schlüssel gilt. Beides gehört festgenagelt: dass frische Ereignisse
# durchkommen, und dass es ohne gültiges Token nichts gibt.
class PublicOverlayControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @user = create(:user, :admin)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @game_day = create(:game_day, league: @league)
    @home = create(:team, league: @league, name: 'Heimverein')
    @guest = create(:team, league: @league, name: 'Gastverein')

    @game = create(:game,
                   game_day: @game_day,
                   home_team: @home,
                   guest_team: @guest,
                   start_time: '18:00',
                   started: true,
                   ended: false,
                   ingame_status: 'period2',
                   record_created_at: 1.hour.ago,
                   players: {
                     'home' => [
                       { 'trikot_number' => 17, 'player_id' => 1, 'player_firstname' => 'Max',
                         'player_name' => 'Mustermann', 'goalkeeper' => false },
                       { 'trikot_number' => 9, 'player_id' => 2, 'player_firstname' => 'Erik',
                         'player_name' => 'Beispiel', 'goalkeeper' => false }
                     ],
                     'guest' => []
                   },
                   events: [
                     { 'id' => 1, 'row' => 1, 'period' => 1, 'time' => '05:00',
                       'event_type' => 'goal', 'event_team' => 'home',
                       'home_number' => 17, 'home_assist' => 9,
                       'home_goals' => 1, 'guest_goals' => 0,
                       'added_at' => 30.minutes.ago.to_i },
                     # Gerade eben eingetragen: Genau dieses Ereignis bleibt
                     # einem API-Schlüssel ohne Echtzeit-Freigabe verborgen und
                     # muss dem Overlay-Token trotzdem geliefert werden.
                     { 'id' => 2, 'row' => 2, 'period' => 2, 'time' => '12:34',
                       'event_type' => 'goal', 'event_team' => 'home',
                       'home_number' => 9,
                       'home_goals' => 2, 'guest_goals' => 0,
                       'added_at' => 30.seconds.ago.to_i }
                   ])

    _link, @token = GameDayOverlayLink.generate!(game_day: @game_day, created_by: @user)
  end

  # ── Zugang ────────────────────────────────────────────────────────────────

  test 'ohne Token gibt es keine Daten' do
    get '/api/v2/public/overlay/live'

    assert_response :bad_request
  end

  test 'ein unbekanntes Token wird abgewiesen' do
    get '/api/v2/public/overlay/live', params: { token: 'gibtesnicht' }

    assert_response :gone
  end

  test 'ein abgelaufenes Token wird abgewiesen' do
    GameDayOverlayLink.find_by_token(@token).update_column(:expires_at, 1.minute.ago)

    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :gone
  end

  test 'ein zurueckgezogenes Token wird abgewiesen' do
    login(@user)
    delete "/api/v2/user/game_days/#{@game_day.id}/overlay_link"
    assert_response :success

    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :gone
  end

  test 'ein neu erzeugtes Token entwertet das alte' do
    login(@user)
    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"
    assert_response :created

    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :gone
  end

  # ── Live-Daten ────────────────────────────────────────────────────────────

  test 'das Overlay bekommt auch das gerade eingetragene Tor' do
    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    game = JSON.parse(response.body)['game']
    assert_equal 2, game['events'].size, 'Die Verzögerung darf hier nicht greifen'
    assert_equal '2:0', game['result_string']
  end

  test 'Gegenprobe: derselbe Stand bleibt einem Schluessel ohne Echtzeit verborgen' do
    raw_key, = ApiKey.generate(name: 'Fremdzugang')

    get "/api/v2/games/#{@game.id}.json", headers: { 'HTTP_X_API_KEY' => raw_key }

    assert_response :success
    assert_equal '1:0', JSON.parse(response.body)['result_string']
  end

  test 'Trikotnummern sind zu Namen aufgeloest' do
    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    goal = JSON.parse(response.body)['game']['events'].find { |e| e['event_id'] == 1 }
    assert_equal 'M. Mustermann', goal['scorer_name']
    assert_equal 'Max Mustermann', goal['scorer_full_name']
    assert_equal 'E. Beispiel', goal['assist_name']
  end

  test 'last_goal nennt das zuletzt gefallene Tor' do
    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    last = JSON.parse(response.body)['game']['last_goal']
    assert_equal 2, last['event_id']
    assert_equal 'E. Beispiel', last['scorer_name']
  end

  test 'Abschnitt und Mannschaftskuerzel liegen bei' do
    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    game = JSON.parse(response.body)['game']
    assert_equal 'period2', game['ingame_status']
    assert game.dig('current_period_title', 'title').present?
    assert_equal 'Heimverein', game.dig('home', 'name')
    assert game.dig('home', 'short_name').present?
  end

  test 'der Spielabruf nennt die Spieltags-Kennung fuer die Token-Anforderung' do
    # Der Spielbericht kennt nur das Spiel, der Overlay-Zugang haengt aber am
    # Spieltag. Ohne diese Kennung koennte die Oberfläche dort kein Token holen.
    raw_key, = ApiKey.generate(name: 'Frontend')

    get "/api/v2/games/#{@game.id}.json", headers: { 'HTTP_X_API_KEY' => raw_key }

    assert_response :success
    assert_equal @game_day.id, JSON.parse(response.body)['game_day_id']
  end

  test 'server_time liegt bei, damit die Uhr den Zeitversatz ausgleichen kann' do
    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    assert JSON.parse(response.body)['server_time'].to_i.positive?
  end

  # ── Sparsame Antwort ──────────────────────────────────────────────────────

  test 'mit bekanntem Stand bleibt der Spielblock weg' do
    get '/api/v2/public/overlay/live', params: { token: @token }
    version = JSON.parse(response.body)['game_version']

    get '/api/v2/public/overlay/live', params: { token: @token, v: version }

    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body['game'], 'Unveraenderte Spieldaten muessen wegbleiben'
    assert_equal version, body['game_version']
  end

  test 'nach einer Aenderung kommt der Spielblock wieder mit' do
    get '/api/v2/public/overlay/live', params: { token: @token }
    version = JSON.parse(response.body)['game_version']

    @game.touch

    get '/api/v2/public/overlay/live', params: { token: @token, v: version }

    assert_response :success
    assert JSON.parse(response.body)['game'].present?
  end

  # ── Spielauswahl ──────────────────────────────────────────────────────────

  test 'ohne Auswahl kommt das erste Spiel des Spieltags' do
    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    assert_equal @game.id, JSON.parse(response.body)['game_id']
  end

  test 'ein Spiel eines fremden Spieltags ist ueber das Token nicht erreichbar' do
    other_day = create(:game_day, league: @league)
    other_game = create(:game, game_day: other_day, home_team: @home, guest_team: @guest)

    get '/api/v2/public/overlay/live', params: { token: @token, game_id: other_game.id }

    assert_response :success
    assert_equal @game.id, JSON.parse(response.body)['game_id'],
                 'Das Token gilt nur fuer seinen Spieltag'
  end

  test 'game_day listet die Spiele fuer die Umschaltung im Dock' do
    get '/api/v2/public/overlay/game_day', params: { token: @token }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @game_day.id, body.dig('game_day', 'id')
    game_ids = body['games'].map { |g| g['id'] }
    assert_equal [@game.id], game_ids
  end

  # ── Steuerzustand ─────────────────────────────────────────────────────────

  test 'das Dock schreibt den Zustand und das Overlay liest ihn' do
    post '/api/v2/public/overlay/state',
         params: { token: @token, state: { scoreboard_visible: true, lower_third: { kind: 'goal' } } },
         as: :json

    assert_response :success

    get '/api/v2/public/overlay/live', params: { token: @token }

    state = JSON.parse(response.body)['state']
    assert_equal true, state['scoreboard_visible']
    assert_equal 'goal', state.dig('lower_third', 'kind')
  end

  # Ein einziger krummer Schreibvorgang legte sonst alle Browser-Quellen und
  # Docks dieses Spieltags lahm: resolve_game ruft `dig` auf dem Zustand auf.
  test 'ein Zustand, der kein Objekt ist, wird abgewiesen' do
    post '/api/v2/public/overlay/state', params: { token: @token, state: 'kaputt' }, as: :json

    assert_response :bad_request

    get '/api/v2/public/overlay/live', params: { token: @token }
    assert_response :success
  end

  test 'eine Liste als Zustand wird abgewiesen' do
    post '/api/v2/public/overlay/state', params: { token: @token, state: [1, 2, 3] }, as: :json

    assert_response :bad_request
  end

  test 'ein uebergrosser Zustand wird abgewiesen' do
    post '/api/v2/public/overlay/state',
         params: { token: @token, state: { blob: 'x' * 20_000 } }, as: :json

    assert_response :payload_too_large
  end

  test 'ein state_updated_at, das keine Zahl ist, endet nicht im Serverfehler' do
    post '/api/v2/public/overlay/state',
         params: { token: @token, state: { a: 1 }, state_updated_at: { x: 1 } }, as: :json

    assert_response :success
  end

  # server_time dient dem Uhrenabgleich. Läge es im zwischengespeicherten
  # Spielblock, wäre es bis zu eine Minute alt und damit wertlos.
  test 'server_time steht nur in der Antwort, nicht im gecachten Spielblock' do
    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    body = JSON.parse(response.body)
    assert body['server_time'].to_i.positive?
    assert_nil body['game']['server_time']
  end

  test 'ein Schreibvorgang auf altem Stand wird abgewiesen' do
    post '/api/v2/public/overlay/state', params: { token: @token, state: { scoreboard_visible: true } },
                                         as: :json
    assert_response :success
    first = JSON.parse(response.body)['state_updated_at']

    travel 1.second do
      post '/api/v2/public/overlay/state',
           params: { token: @token, state: { scoreboard_visible: false } }, as: :json
      assert_response :success

      # Zweites Dock schreibt auf dem Stand von vorhin.
      post '/api/v2/public/overlay/state',
           params: { token: @token, state: { scoreboard_visible: true }, state_updated_at: first },
           as: :json

      assert_response :conflict
    end
  end

  test 'die Spielauswahl des Docks steuert, welches Spiel das Overlay zeigt' do
    second = create(:game, game_day: @game_day, home_team: @guest, guest_team: @home, start_time: '20:00')

    post '/api/v2/public/overlay/state', params: { token: @token, state: { active_game_id: second.id } },
                                         as: :json
    assert_response :success

    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_equal second.id, JSON.parse(response.body)['game_id']
  end

  # ── Auszeichnungen ────────────────────────────────────────────────────────

  test 'die Auszeichnungen des Spiels kommen mit' do
    @game.update!(awards: { 'home' => { 'mvp' => 1 }, 'guest' => {} })

    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    awards = JSON.parse(response.body)['game']['awards']
    assert_equal 'Mustermann', awards['home'].first['player_name']
    # Ohne Auszeichnung bleibt der Eintrag leer, statt zu fehlen: Das
    # Endstandbild muss damit nur einen Fall behandeln.
    assert_equal '', awards['guest'].first['player_id']
  end

  # ── Ligaweite Vollbilder ──────────────────────────────────────────────────

  test 'Tabelle und Scorerliste sind mit dem Spieltags-Token erreichbar' do
    get '/api/v2/public/overlay/table', params: { token: @token }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @league.id, body['league']['id']
    assert body['table'].is_a?(Array)

    get '/api/v2/public/overlay/scorer', params: { token: @token }
    assert_response :success
    assert JSON.parse(response.body)['scorer'].is_a?(Array)
  end

  test 'ohne gueltiges Token gibt es auch die Ligadaten nicht' do
    get '/api/v2/public/overlay/table'
    assert_response :bad_request

    get '/api/v2/public/overlay/scorer', params: { token: 'gibtesnicht' }
    assert_response :gone

    get '/api/v2/public/overlay/schedule', params: { token: 'gibtesnicht' }
    assert_response :gone
  end

  # Der Zugang ist an den Spieltag gebunden und nicht frei wählbar. Gäbe es
  # einen league_id-Parameter, wäre aus dem Token ein Generalschlüssel für den
  # Live-Bestand jeder Liga geworden.
  test 'eine fremde Liga laesst sich nicht anfordern' do
    fremde = create(:league, game_operation: @go, name: 'Fremde Liga')

    get '/api/v2/public/overlay/table', params: { token: @token, league_id: fremde.id }

    assert_response :success
    assert_equal @league.id, JSON.parse(response.body)['league']['id']
  end

  test 'ein Spieltag ohne Liga endet nicht im Serverfehler' do
    @game_day.update_column(:league_id, nil)

    get '/api/v2/public/overlay/table', params: { token: @token }

    assert_response :not_found
  end

  # ── Die Verzögerung endet am eigenen Spieltag ─────────────────────────────
  # Das Token hebt sie nur für die Spiele SEINES Spieltags auf. Eine parallel
  # laufende Partie in einer anderen Halle steht ohne Zwischenstand im
  # Spielplan. `delay_live_scores` aus dem ApplicationController greift hier
  # nicht (delay_live_data? ist ohne API-Key immer false), deshalb muss der
  # eigene Filter das leisten.
  test 'parallel laufende Partien kommen ohne Zwischenstand' do
    parallel_day = create(:game_day, league: @league, number: @game_day.number)
    parallel_game = create(:game, game_day: parallel_day,
                                  home_team: create(:team, league: @league, name: 'Dritter'),
                                  guest_team: create(:team, league: @league, name: 'Vierter'),
                                  started: true, ended: false,
                                  events: [{ 'row' => 1, 'period' => 1, 'event_type' => 'goal',
                                             'event_team' => 'home', 'home_number' => 5,
                                             'home_goals' => 4, 'guest_goals' => 1,
                                             'added_at' => 30.seconds.ago.to_i }])

    get '/api/v2/public/overlay/schedule', params: { token: @token }

    assert_response :success
    schedule = JSON.parse(response.body)['schedule']

    fremd = schedule.find { |g| g['game_id'] == parallel_game.id }
    assert fremd.present?, 'die parallele Partie fehlt im Spielplan'
    assert_nil fremd['result'], 'der Zwischenstand der fremden Halle darf nicht mitkommen'
    assert_nil fremd['result_string']

    eigen = schedule.find { |g| g['game_id'] == @game.id }
    assert_equal '2:0', eigen['result_string'], 'das eigene Spiel bleibt live'
  end

  test 'beendete Partien anderer Hallen behalten ihren Endstand' do
    parallel_day = create(:game_day, league: @league, number: @game_day.number)
    beendet = create(:game, :with_result, game_day: parallel_day,
                                          home_team: create(:team, league: @league),
                                          guest_team: create(:team, league: @league),
                                          ended: true)

    get '/api/v2/public/overlay/schedule', params: { token: @token }

    assert_response :success
    eintrag = JSON.parse(response.body)['schedule'].find { |g| g['game_id'] == beendet.id }
    assert_equal '3:1', eintrag['result_string']
  end

  # Ohne diesen Hinweis sieht eine unvollständige Tabelle auf Sendung wie ein
  # Fehler aus. Das eigene Spiel läuft ebenfalls, ist aber vollständig zu sehen
  # und deshalb gesondert markiert.
  test 'running_games weist laufende Partien aus und trennt die eigene ab' do
    parallel_day = create(:game_day, league: @league, number: @game_day.number)
    parallel_game = create(:game, game_day: parallel_day,
                                  home_team: create(:team, league: @league),
                                  guest_team: create(:team, league: @league),
                                  started: true, ended: false)

    get '/api/v2/public/overlay/table', params: { token: @token }

    assert_response :success
    running = JSON.parse(response.body)['running_games']
    assert_equal [@game.id, parallel_game.id].sort, running.map { |r| r['game_id'] }.sort

    assert running.find { |r| r['game_id'] == @game.id }['own_game_day']
    assert_not running.find { |r| r['game_id'] == parallel_game.id }['own_game_day']
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
