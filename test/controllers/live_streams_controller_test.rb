require 'test_helper'

# Was heute übertragen wird. Anders als beim Overlay-Token gilt hier die normale
# Regel: Ein API-Schlüssel ohne Echtzeit-Freigabe bekommt die Zwischenstände
# laufender Partien erst nach zehn Minuten. Genau das gehört festgenagelt,
# sonst entsteht über diesen Abruf die Lücke, die an zwei anderen schon
# geschlossen wurde.
class LiveStreamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation)
    @league = create(:league, game_operation: @go, name: '1. Bundesliga Herren')
    # `game_days.date` ist ein lokales Datum; derselbe Kalender wie im
    # Controller, sonst legt der Test zwischen 22 und 24 Uhr UTC ein Spiel von
    # gestern an und die Liste ist zu Recht leer.
    @today = RefereeFeedbackWindow.today.to_s
    @game_day = create(:game_day, league: @league, date: @today)

    @home = create(:team, league: @league, name: 'Heimverein')
    @guest = create(:team, league: @league, name: 'Gastverein')

    @laufend = create(:game, game_day: @game_day, home_team: @home, guest_team: @guest,
                             start_time: '18:00', started: true, ended: false,
                             live_stream_link: 'https://stream.example/live',
                             events: [{ 'row' => 1, 'period' => 1, 'event_type' => 'goal',
                                        'event_team' => 'home', 'home_number' => 7,
                                        'home_goals' => 3, 'guest_goals' => 1,
                                        'added_at' => 30.seconds.ago.to_i }])
  end

  def api_key_headers(realtime: false)
    raw, key = ApiKey.generate(name: "Zugang #{realtime}")
    key.update!(realtime: true) if realtime
    { 'HTTP_X_API_KEY' => raw }
  end

  test 'ohne Schluessel und ohne Anmeldung gibt es nichts' do
    get '/api/v2/live_streams'

    assert_response :unauthorized
  end

  test 'die Spiele des Tages mit Stream-Link kommen mit' do
    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @today, body['date']
    eintrag = body['games'].find { |g| g['game_id'] == @laufend.id }
    assert eintrag.present?
    assert_equal 'running', eintrag['status']
    assert_equal 'https://stream.example/live', eintrag['live_stream_link']
    assert_equal '1. Bundesliga Herren', eintrag['league']['name']
  end

  test 'Spiele ohne Stream-Link und ohne Aufzeichnung bleiben draussen' do
    ohne = create(:game, game_day: @game_day, home_team: @home, guest_team: @guest, start_time: '20:00')

    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    ids = JSON.parse(response.body)['games'].map { |g| g['game_id'] }
    assert_not_includes ids, ohne.id
  end

  test 'Spiele anderer Tage bleiben draussen' do
    anderer_tag = create(:game_day, league: @league, date: 3.days.from_now.to_date.to_s)
    morgen = create(:game, game_day: anderer_tag, home_team: @home, guest_team: @guest,
                           live_stream_link: 'https://stream.example/spaeter')

    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    ids = JSON.parse(response.body)['games'].map { |g| g['game_id'] }
    assert_not_includes ids, morgen.id
  end

  # `game_days.date` ist eine Textspalte. Ein leerer Wert oder "TBD" darf den
  # Abruf nicht mit in einen Serverfehler reissen — ein Textvergleich trifft ihn
  # schlicht nicht, TO_DATE haette daran geworfen.
  test 'ein unbrauchbares Spieltagsdatum reisst den Abruf nicht mit' do
    kaputt = create(:game_day, league: @league)
    kaputt.update_column(:date, 'TBD')
    create(:game, game_day: kaputt, home_team: @home, guest_team: @guest,
                  live_stream_link: 'https://stream.example/tbd')

    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
  end

  # ── Verzögerung ───────────────────────────────────────────────────────────

  test 'ein Schluessel ohne Echtzeit-Freigabe sieht den Zwischenstand nicht' do
    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    eintrag = JSON.parse(response.body)['games'].find { |g| g['game_id'] == @laufend.id }
    assert_nil eintrag['result_string'], 'der Zwischenstand einer laufenden Partie muss zurueckgehalten werden'
    assert_nil eintrag['result']
  end

  test 'ein Schluessel mit Echtzeit-Freigabe sieht ihn' do
    get '/api/v2/live_streams', headers: api_key_headers(realtime: true)

    assert_response :success
    eintrag = JSON.parse(response.body)['games'].find { |g| g['game_id'] == @laufend.id }
    assert_equal '3:1', eintrag['result_string']
  end

  # Ein angepfiffenes Spiel ohne angelegten Spielbericht ist trotzdem laufend.
  # Haenge der Status an `state == :running`, rutschte es als „anstehend" durch
  # und mit ihm sein Zwischenstand.
  test 'ein begonnenes Spiel ohne Bericht gilt als laufend und wird verzoegert' do
    @laufend.update!(record_created_at: nil)

    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    eintrag = JSON.parse(response.body)['games'].find { |g| g['game_id'] == @laufend.id }
    assert_equal 'running', eintrag['status']
    assert_nil eintrag['result_string']
  end

  test 'beendete Partien nennen Endstand und Aufzeichnung sofort' do
    beendet = create(:game, :with_result, game_day: @game_day,
                                          home_team: @home, guest_team: @guest,
                                          start_time: '16:00', ended: true,
                                          live_stream_link: 'https://stream.example/frueher',
                                          vod_link: 'https://stream.example/vod')

    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    eintrag = JSON.parse(response.body)['games'].find { |g| g['game_id'] == beendet.id }
    assert_equal 'ended', eintrag['status']
    assert_equal '3:1', eintrag['result_string']
    assert_equal 'https://stream.example/vod', eintrag['vod_link']
  end

  test 'eine reine Aufzeichnung ohne Stream-Link kommt ebenfalls mit' do
    nur_vod = create(:game, :with_result, game_day: @game_day,
                                          home_team: @home, guest_team: @guest,
                                          start_time: '14:00', ended: true,
                                          vod_link: 'https://stream.example/nur-vod')

    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    ids = JSON.parse(response.body)['games'].map { |g| g['game_id'] }
    assert_includes ids, nur_vod.id
  end

  # ── Reihenfolge ───────────────────────────────────────────────────────────

  test 'laufende zuerst, dann anstehende, darunter die beendeten' do
    create(:game, game_day: @game_day, home_team: @home, guest_team: @guest,
                  start_time: '20:00', live_stream_link: 'https://stream.example/spaeter')
    create(:game, :with_result, game_day: @game_day, home_team: @home, guest_team: @guest,
                                start_time: '16:00', ended: true,
                                live_stream_link: 'https://stream.example/frueher')

    get '/api/v2/live_streams', headers: api_key_headers

    assert_response :success
    stati = JSON.parse(response.body)['games'].map { |g| g['status'] }
    assert_equal %w[running upcoming ended], stati
  end
end
