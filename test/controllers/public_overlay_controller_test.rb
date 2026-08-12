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

  # Absichtlich anders als überall sonst: `League#resolved_logo` fällt auf den
  # Landesverband zurück, das Overlay nicht. In der Anzeigetafel steht das
  # Zeichen stellvertretend für den Wettbewerb, ein Verbandslogo an dieser
  # Stelle behauptete etwas Falsches. Ohne eigenes Ligazeichen bleibt deshalb
  # das mitgelieferte Bundesliga-Zeichen stehen.
  test 'das Overlay bekommt das Logo der Liga, wenn sie eines hat' do
    @league.logo.attach(io: File.open(logo_png), filename: 'liga.png', content_type: 'image/png')

    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    assert JSON.parse(response.body).dig('game', 'league', 'logo_url').present?
  end

  test 'das Logo des Landesverbands kommt im Overlay nicht durch' do
    @sa.logo.attach(io: File.open(logo_png), filename: 'sa.png', content_type: 'image/png')

    get '/api/v2/public/overlay/live', params: { token: @token }

    assert_response :success
    assert_nil JSON.parse(response.body).dig('game', 'league', 'logo_url')
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

  private

  # Ein winziges, gültiges PNG. Die Tempfile-Referenz muss leben bleiben:
  # Wird sie eingesammelt, ist die Datei weg, bevor jemand sie liest.
  def logo_png
    @logo_file ||= Tempfile.new(['logo', '.png'])
    @logo_png ||= begin
      Vips::Image.black(120, 60).add(200).cast('uchar').write_to_file(@logo_file.path)
      @logo_file.path
    end
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
