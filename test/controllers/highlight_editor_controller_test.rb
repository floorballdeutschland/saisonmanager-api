require 'test_helper'

# Kalibrierung und Szenenauswahl per Mail-Link oder als SBK (fe#560).
class HighlightEditorControllerTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date: '2026-10-11')
    @start = Time.zone.parse('2026-10-11 17:50:00')
    @game = Game.create!(game_day: @game_day,
                         home_team: create(:team, league: @league, club: @club),
                         guest_team: create(:team, league: @league, club: create(:club)),
                         forfait: 0, overtime: false, legacy: false, ended: true, tablet_capture_at: @start,
                         players: { 'home' => [{ 'trikot_number' => 7, 'player_firstname' => 'Max',
                                                 'player_name' => 'Müller' }], 'guest' => [] },
                         events: [{ 'id' => 1, 'event_type' => 'goal', 'event_team' => 'home', 'period' => 1,
                                    'time' => '11:00', 'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 7,
                                    'added_at' => (@start + 40.minutes).to_i }])
    @game.update_columns(live_stream_link: 'https://www.youtube.com/watch?v=vid-1')
    @broadcast = StreamBroadcast.create!(broadcast_id: 'vid-1', game: @game, actual_start_at: @start,
                                         vod_duration_seconds: 7200)
    GameShot.create!(game: @game, client_uuid: 's1', team: 'home', period: 1, tapped_at: @start + 38.minutes,
                     x: 0.8, y: 0.5, result: 'goal', event_id: 1)
    GameShot.create!(game: @game, client_uuid: 'm1', kind: 'mark', period: 2, game_time: '04:00',
                     tapped_at: @start + 50.minutes)
    GameShot.create!(game: @game, client_uuid: 'f1', kind: 'free_hit', team: 'home', period: 1,
                     tapped_at: @start + 30.minutes, x: 0.5, y: 0.5)
    @link, @secretary_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))
  end

  # --- Anfrage beim Beenden -------------------------------------------------------

  test 'Sekretariats-Link mit Adresse legt eine Anfrage an, doppelt bleibt einfach' do
    2.times do
      post "/api/v2/games/#{@game.id}/highlight_request.json", params: { email: 'Hallo@Verein.de' },
                                                                headers: secretary_header, as: :json
      assert_response :accepted
    end
    post "/api/v2/games/#{@game.id}/highlight_request.json", params: { email: 'hallo@verein.de' },
                                                              headers: secretary_header, as: :json

    assert_equal 1, TabletHighlightRequest.count
    anfrage = TabletHighlightRequest.last
    assert_equal 'Hallo@Verein.de', anfrage.email
    assert_nil anfrage.token_digest, 'Token entsteht erst beim Versand'
  end

  test 'Sekretariats-Link ohne oder mit kaputter Adresse: 422' do
    post "/api/v2/games/#{@game.id}/highlight_request.json", params: {}, headers: secretary_header, as: :json
    assert_response :unprocessable_entity

    post "/api/v2/games/#{@game.id}/highlight_request.json", params: { email: 'kein-at' },
                                                              headers: secretary_header, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, TabletHighlightRequest.count
  end

  test 'angemeldet ohne Adresse: Kontoadresse, gespeichert wird nur die user_id' do
    user = create(:user, :sbk_scoped, game_operation_id: @go.id, email: 'sbk@verband.de')
    login_as(user)

    post "/api/v2/games/#{@game.id}/highlight_request.json", params: {}, as: :json

    assert_response :accepted
    anfrage = TabletHighlightRequest.last
    assert_equal user.id, anfrage.user_id
    assert_nil anfrage.email
    assert_equal 'sbk@verband.de', anfrage.recipient
  end

  test 'ohne Berechtigung am Spiel 403, ohne Tabletmodus 422' do
    fremd = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 2, date: '2026-10-18')
    @game.update_columns(game_day_id: fremd.id)
    post "/api/v2/games/#{@game.id}/highlight_request.json", params: { email: 'a@b.de' },
                                                              headers: secretary_header, as: :json
    assert_response :forbidden

    @game.update_columns(game_day_id: @game_day.id, tablet_capture_at: nil)
    post "/api/v2/games/#{@game.id}/highlight_request.json", params: { email: 'a@b.de' },
                                                              headers: secretary_header, as: :json
    assert_response :unprocessable_entity
  end

  test 'höchstens fünf offene Anfragen je Spiel' do
    5.times do |i|
      post "/api/v2/games/#{@game.id}/highlight_request.json", params: { email: "p#{i}@verein.de" },
                                                                headers: secretary_header, as: :json
    end
    post "/api/v2/games/#{@game.id}/highlight_request.json", params: { email: 'p9@verein.de' },
                                                              headers: secretary_header, as: :json

    assert_response :unprocessable_entity
    assert_equal 5, TabletHighlightRequest.count
  end

  # --- Mail-Link ---------------------------------------------------------------

  test 'Token liefert Video, Kalibrierszene und alle Szenen samt abgewählter, ohne Freischläge' do
    GameShot.find_by(client_uuid: 'm1').update!(in_highlights: false)
    token = gesendeter_token

    get "/api/v2/highlight_editor.json?token=#{token}"

    assert_response :success
    body = response.parsed_body
    assert_equal 'vid-1', body['video_id']
    assert_nil body['offset_seconds']
    assert_equal({ 'client_uuid' => 's1', 'anchor_second' => 2280 }, body['calibration_scene'])
    assert_equal(%w[s1 m1], body['scenes'].map { |s| s['client_uuid'] })
    tor, marke = body['scenes']
    assert_equal ['goal', '1:0 Müller', 2265, 2285, true], tor.values_at('kind', 'label', 'start', 'end', 'in_highlights')
    assert_equal ['mark', 'Vorgemerkte Szene', false], marke.values_at('kind', 'label', 'in_highlights')
    assert body['expires_at'].present?
    assert_not_includes response.body, 'f1'
  end

  test 'Token speichert Versatz und Auswahl, öffentliche Highlights folgen sofort' do
    token = gesendeter_token
    with_real_cache do
      get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }
      assert_equal 2, response.parsed_body['scenes'].size

      put "/api/v2/highlight_editor.json?token=#{token}",
          params: { offset_seconds: 18, scenes: [{ client_uuid: 'm1', in_highlights: false }] }, as: :json

      assert_response :success
      assert_equal 18, response.parsed_body['offset_seconds']
      @broadcast.reload
      assert_equal [18, 'link', nil], [@broadcast.offset_seconds, @broadcast.calibrated_via, @broadcast.calibrated_by_user_id]

      get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }
      scenes = response.parsed_body['scenes']
      assert_equal(['goal'], scenes.map { |s| s['kind'] })
      assert_equal [2280 + 18 - 12, 2280 + 18 + 8], scenes.first.values_at('start', 'end')
    end
  end

  test 'offset_seconds null nimmt die Kalibrierung zurück, fehlender Schlüssel lässt sie stehen' do
    @broadcast.update!(offset_seconds: 10, calibrated_at: Time.current, calibrated_via: 'link')
    token = gesendeter_token

    put "/api/v2/highlight_editor.json?token=#{token}", params: { scenes: [] }, as: :json
    assert_equal 10, @broadcast.reload.offset_seconds

    put "/api/v2/highlight_editor.json?token=#{token}", params: { offset_seconds: nil }, as: :json
    assert_response :success
    assert_nil @broadcast.reload.offset_seconds
    assert_nil @broadcast.calibrated_via
  end

  test 'ungültige Eingaben: Versatz außerhalb, Freischlag oder fremde Szene, alles oder nichts' do
    token = gesendeter_token

    put "/api/v2/highlight_editor.json?token=#{token}", params: { offset_seconds: 500 }, as: :json
    assert_response :unprocessable_entity

    put "/api/v2/highlight_editor.json?token=#{token}",
        params: { offset_seconds: 12, scenes: [{ client_uuid: 'f1', in_highlights: false }] }, as: :json
    assert_response :unprocessable_entity
    assert_nil @broadcast.reload.offset_seconds, 'nichts gespeichert'

    put "/api/v2/highlight_editor.json?token=#{token}",
        params: { scenes: [{ client_uuid: 'm1', in_highlights: 'ja' }] }, as: :json
    assert_response :unprocessable_entity
  end

  test 'unbekannter Token 404, abgelaufener 410' do
    get '/api/v2/highlight_editor.json?token=gibtsnicht'
    assert_response :not_found

    token = gesendeter_token
    TabletHighlightRequest.last.update!(expires_at: 1.minute.ago)
    get "/api/v2/highlight_editor.json?token=#{token}"
    assert_response :gone
  end

  test 'abgelaufen bleibt 410, auch nachdem der Wächter aufgeräumt hat' do
    token = gesendeter_token
    TabletHighlightRequest.last.update!(expires_at: 1.day.ago)

    TabletHighlightLinks.new.run
    get "/api/v2/highlight_editor.json?token=#{token}"

    assert_response :gone
  end

  test 'kaputte Einträge in scenes: 422 statt 500' do
    token = gesendeter_token

    put "/api/v2/highlight_editor.json?token=#{token}", params: { scenes: ['m1'] }, as: :json
    assert_response :unprocessable_entity

    put "/api/v2/highlight_editor.json?token=#{token}", params: { scenes: [1] }, as: :json
    assert_response :unprocessable_entity
  end

  # --- Tor-Zuordnung (Spiel 58763) ------------------------------------------------

  test 'Editor listet die Tore und Tor-Schüsse ohne Tor, öffentlich bleiben diese draußen' do
    zwei_tore_und_ein_fehltipper

    get "/api/v2/highlight_editor.json?token=#{gesendeter_token}"

    body = response.parsed_body
    assert_equal([[1, 'home'], [2, 'home'], [3, 'guest']], body['goals'].map { |g| g.values_at('event_id', 'team') })
    assert_equal ['1:0 Müller', '2:0 Müller'], body['goals'].first(2).pluck('label')
    szenen = body['scenes'].index_by { |s| s['client_uuid'] }
    assert_equal ['goal', 1], szenen['s1'].values_at('kind', 'event_id')
    assert_equal ['unlinked', nil, 'Tor-Schuss ohne Tor im Bericht'], szenen['s3'].values_at('kind', 'event_id', 'label')

    with_real_cache do
      get "/api/v2/games/#{@game.id}/highlights.json", headers: { 'X-Api-Key' => API_KEY }
      assert_not_includes response.parsed_body['scenes'].map { |s| s['kind'] }, 'unlinked'
      assert_equal 3, response.parsed_body['scenes'].size, 's1, s2 und die Marke'
    end
  end

  test 'Zuordnung verschiebt die Tore zurück und macht den Fehltipper zum Fehlschuss' do
    zwei_tore_und_ein_fehltipper
    @broadcast.update_columns(chapters_checked_at: Time.current)

    put "/api/v2/highlight_editor.json?token=#{gesendeter_token}",
        params: { assignments: [{ client_uuid: 's1', event_id: nil, result: 'missed' },
                                { client_uuid: 's2', event_id: 1 },
                                { client_uuid: 's3', event_id: 2 }] }, as: :json

    assert_response :success
    assert_equal({ 's1' => ['missed', nil], 's2' => ['goal', 1], 's3' => ['goal', 2] },
                 GameShot.where(client_uuid: %w[s1 s2 s3]).to_h { |s| [s.client_uuid, [s.result, s.event_id]] })
    assert_nil @broadcast.reload.chapters_checked_at, 'Sprungmarken werden neu gerechnet'
    assert_equal(%w[s2 s3], response.parsed_body['scenes'].select { |s| s['kind'] == 'goal' }.pluck('client_uuid'))
  end

  test 'Zuordnung an ein belegtes Tor löst den bisherigen Schuss' do
    zwei_tore_und_ein_fehltipper

    put "/api/v2/highlight_editor.json?token=#{gesendeter_token}",
        params: { assignments: [{ client_uuid: 's3', event_id: 1 }] }, as: :json

    assert_response :success
    assert_equal [1, nil], [GameShot.find_by(client_uuid: 's3').event_id, GameShot.find_by(client_uuid: 's1').event_id]
    assert_equal 'goal', GameShot.find_by(client_uuid: 's1').result
  end

  test 'ungültige Zuordnungen: 422 und nichts gespeichert' do
    zwei_tore_und_ein_fehltipper
    token = gesendeter_token
    falsch = [
      [{ client_uuid: 's3', event_id: 3 }],                                        # fremde Mannschaft
      [{ client_uuid: 's3', event_id: 99 }],                                       # Tor gibt es nicht
      [{ client_uuid: 's3', event_id: 1 }, { client_uuid: 's2', event_id: 1 }], # Tor doppelt
      [{ client_uuid: 's3', event_id: nil }],                                      # ohne Tor kein Ergebnis
      [{ client_uuid: 's3', event_id: nil, result: 'goal' }],
      [{ client_uuid: 'f1', event_id: 1 }],                                        # Freischlag
      [{ client_uuid: 'm1', event_id: 1 }],                                        # Marke
      [{ client_uuid: 's3', event_id: false }],                                    # keine Zahl
      [{ client_uuid: 's3', event_id: { id: 1 } }],
      [{ client_uuid: 's3', event_id: [1] }],
      [{ client_uuid: 's3', event_id: 1.5 }],
      ['s3']
    ]
    falsch.each do |zuordnung|
      put "/api/v2/highlight_editor.json?token=#{token}", params: { offset_seconds: 4, assignments: zuordnung },
                                                          as: :json
      assert_response :unprocessable_entity, zuordnung.inspect
    end

    assert_nil @broadcast.reload.offset_seconds
    assert_equal({ 's1' => 1, 's2' => 2, 's3' => nil },
                 GameShot.where(client_uuid: %w[s1 s2 s3]).to_h { |s| [s.client_uuid, s.event_id] })
  end

  # --- Admin und SBK -------------------------------------------------------------

  test 'SBK des Spielbetriebs korrigiert ohne Link, mit Konto vermerkt' do
    user = create(:user, :sbk_scoped, game_operation_id: @go.id)
    login_as(user)

    get "/api/v2/games/#{@game.id}/highlight_editor.json"
    assert_response :success
    assert_nil response.parsed_body['expires_at']

    put "/api/v2/games/#{@game.id}/highlight_editor.json", params: { offset_seconds: -3 }, as: :json
    assert_response :success
    assert_equal [-3, 'user', user.id], @broadcast.reload.values_at(:offset_seconds, :calibrated_via, :calibrated_by_user_id)
  end

  test 'fremde SBK 403, ohne Anmeldung 401' do
    get "/api/v2/games/#{@game.id}/highlight_editor.json"
    assert_response :unauthorized

    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id + 1000))
    put "/api/v2/games/#{@game.id}/highlight_editor.json", params: { offset_seconds: 5 }, as: :json
    assert_response :forbidden
    assert_nil @broadcast.reload.offset_seconds
  end

  test 'ohne veröffentlichte Aufzeichnung: lesen leer, schreiben 422' do
    @game.update_columns(live_stream_link: nil)
    login_as(create(:user, :admin))

    get "/api/v2/games/#{@game.id}/highlight_editor.json"
    assert_nil response.parsed_body['video_id']

    put "/api/v2/games/#{@game.id}/highlight_editor.json", params: { offset_seconds: 5 }, as: :json
    assert_response :unprocessable_entity
  end

  private

  def secretary_header
    { 'X-Secretary-Token' => @secretary_token }
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # Wie Spiel 58763: s1 ist ein als Tor getippter Fehlschuss, an dem das erste
  # Tor hängt; das zweite hängt an s2, das eigentlich das erste war, und s3 (das
  # zweite) hängt an nichts. Tor 3 gehört dem Gast.
  def zwei_tore_und_ein_fehltipper
    tor = lambda { |id, team, zeit, heim, gast|
      { 'id' => id, 'event_type' => 'goal', 'event_team' => team, 'period' => 1, 'time' => zeit,
        'home_goals' => heim, 'guest_goals' => gast, "#{team}_number" => (team == 'home' ? 7 : 9),
        'added_at' => (@start + 40.minutes).to_i }
    }
    @game.update_columns(events: [tor.call(1, 'home', '11:00', 1, 0), tor.call(2, 'home', '15:00', 2, 0),
                                  tor.call(3, 'guest', '16:00', 2, 1)])
    GameShot.create!(game: @game, client_uuid: 's2', team: 'home', period: 1, tapped_at: @start + 42.minutes,
                     x: 0.8, y: 0.5, result: 'goal', event_id: 2)
    GameShot.create!(game: @game, client_uuid: 's3', team: 'home', period: 1, tapped_at: @start + 46.minutes,
                     x: 0.8, y: 0.5, result: 'goal')
  end

  def gesendeter_token
    TabletHighlightRequest.create!(game: @game, email: 'a@b.de').issue_token!
  end
end
