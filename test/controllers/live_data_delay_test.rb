require 'test_helper'

# Die Nutzungsvereinbarung sagt fremden API-Zugängen zu, dass sie öffentliche
# Daten mit zehn Minuten Verzögerung bekommen und Ergebnisse laufender Spiele
# nicht sehen. Durchgesetzt wird das an genau zwei Stellen:
# `strip_delayed_events!` für ein einzelnes Spiel und `delay_live_scores` für
# Spielplan-Listen (beide in ApplicationController).
#
# Der Test deckt alle öffentlichen Endpunkte ab, die eines von beidem
# ausliefern. Er ist entstanden, weil zwei davon die Filterung gar nicht
# aufriefen: der v1-Ticker und die Team-Spielliste. Kommt ein neuer öffentlicher
# Endpunkt mit Spielstand dazu, gehört er hier dazu.
class LiveDataDelayTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @game_day = create(:game_day, league: @league)
    @home = create(:team, league: @league)
    @guest = create(:team, league: @league)

    # Laufendes Spiel: ein Tor von vor einer halben Stunde, eines von gerade
    # eben. Verzögert darf nur das alte durchkommen, also 1:0 statt 2:0.
    @game = create(:game,
                   game_day: @game_day,
                   home_team: @home,
                   guest_team: @guest,
                   started: true,
                   ended: false,
                   record_created_at: 2.hours.ago,
                   events: [
                     { 'row' => 1, 'period' => 1, 'time' => '05:00', 'home_number' => 7,
                       'event_type' => 'goal', 'home_goals' => 1, 'guest_goals' => 0,
                       'added_at' => 30.minutes.ago.to_i },
                     { 'row' => 2, 'period' => 1, 'time' => '15:00', 'home_number' => 9,
                       'event_type' => 'goal', 'home_goals' => 2, 'guest_goals' => 0,
                       'added_at' => 1.minute.ago.to_i }
                   ])

    @delayed_key, = ApiKey.generate(name: 'Fremdzugang')
    @realtime_raw, realtime_key = ApiKey.generate(name: 'Partnerzugang')
    realtime_key.update!(realtime: true)
  end

  def header(raw_key)
    { 'HTTP_X_API_KEY' => raw_key }
  end

  # ── v1-Ticker ─────────────────────────────────────────────────────────────
  # `ticker_hash` baut Ereignisliste UND resultString aus `events`. Ohne Filter
  # war das der bequemste Weg an den Live-Stand, den v2 vorenthält.

  test 'v1-Ticker verbirgt frische Ereignisse vor einem Zugang ohne Echtzeit' do
    get "/api/v1/ticker/games/#{@game.id}", headers: header(@delayed_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body['events'].size, 'Das Tor von gerade eben darf nicht dabei sein'
    assert_equal '1:0', body['resultString']
  end

  test 'v1-Ticker liefert einem Echtzeit-Zugang den vollen Stand' do
    get "/api/v1/ticker/games/#{@game.id}", headers: header(@realtime_raw)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body['events'].size
    assert_equal '2:0', body['resultString']
  end

  test 'v1-Ticker meldet weiterhin, dass das Spiel läuft' do
    # Verzögert wird der Stand, nicht die Tatsache. Sonst wäre ein laufendes
    # Spiel für Dritte nicht von einem noch nicht angepfiffenen zu unterscheiden.
    get "/api/v1/ticker/games/#{@game.id}", headers: header(@delayed_key)

    assert_response :success
    assert JSON.parse(response.body)['isLive']
  end

  # ── Team-Spielliste ───────────────────────────────────────────────────────
  # Baut auf `schedule_item` auf, das für begonnene Spiele result und
  # result_string enthält, rief `delay_live_scores` aber nie auf.

  test 'Team-Spielliste nimmt einem Zugang ohne Echtzeit das Ergebnis des laufenden Spiels' do
    get "/api/v2/teams/#{@home.id}/matches", headers: header(@delayed_key)

    assert_response :success
    match = JSON.parse(response.body)['matches'].find { |m| m['game_id'] == @game.id }
    assert match, 'Das Spiel muss in der Liste stehen, nur ohne Ergebnis'
    assert_nil match['result']
    assert_nil match['result_string']
  end

  test 'Team-Spielliste liefert einem Echtzeit-Zugang das Ergebnis' do
    get "/api/v2/teams/#{@home.id}/matches", headers: header(@realtime_raw)

    assert_response :success
    match = JSON.parse(response.body)['matches'].find { |m| m['game_id'] == @game.id }
    assert_equal '2:0', match['result_string']
  end

  test 'Team-Spielliste zeigt beendete Spiele auch verzögert mit Ergebnis' do
    @game.update!(ended: true)

    get "/api/v2/teams/#{@home.id}/matches", headers: header(@delayed_key)

    assert_response :success
    match = JSON.parse(response.body)['matches'].find { |m| m['game_id'] == @game.id }
    assert_equal '2:0', match['result_string'], 'Nur laufende Spiele werden zurückgehalten'
  end

  # ── Spiel-Detail (v2) ─────────────────────────────────────────────────────
  # Hier hat die Verzögerung immer gegriffen; der Test hält das fest, weil die
  # Logik jetzt aus ApplicationController kommt.

  test 'Spiel-Detail verbirgt frische Ereignisse vor einem Zugang ohne Echtzeit' do
    get "/api/v2/games/#{@game.id}.json", headers: header(@delayed_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body['events'].size
    assert_equal '1:0', body['result_string']
  end

  test 'Spiel-Detail liefert einem Echtzeit-Zugang den vollen Stand' do
    get "/api/v2/games/#{@game.id}.json", headers: header(@realtime_raw)

    assert_response :success
    assert_equal '2:0', JSON.parse(response.body)['result_string']
  end
end
