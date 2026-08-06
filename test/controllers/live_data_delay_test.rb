require 'test_helper'

# Die Nutzungsvereinbarung sagt fremden API-Zugängen zehn Minuten Verzögerung
# zu. Durchgesetzt wird das an genau zwei Stellen, beide in
# ApplicationController: `strip_delayed_events!` für ein einzelnes Spiel und
# `delay_live_scores` für Spielplan-Listen.
#
# Zurückgehalten wird nur bei LAUFENDEN Spielen. Ein beendetes Spiel nennt
# seinen Endstand sofort, und zwar aus einem harten Grund: Game#result rechnet
# den Stand vollständig aus den Ereignissen, ein weggelassenes Tor ergibt also
# nicht ein späteres Ergebnis, sondern ein falsches.
#
# Abgedeckt sind die vier öffentlichen Endpunkte, die Spielstände ausliefern:
# v1-Ticker, Spiel-Detail, Team-Spielliste und Liga-Spielplan. Zwei davon
# riefen die Filterung überhaupt nicht auf, daher diese Datei. Kommt ein
# weiterer Endpunkt mit Spielstand dazu, gehört er hier hinein.
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

  def schedule_entry(body)
    body.find { |g| g['game_id'] == @game.id }
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

  # ── Beendete Spiele ───────────────────────────────────────────────────────
  # Der wunde Punkt beim Filtern nach `added_at`: Game#result rechnet den Stand
  # vollständig aus den Ereignissen. Ein weggelassenes Tor verzögert das
  # Ergebnis also nicht, es ergibt ein anderes. Bei einem beendeten Spiel stünde
  # damit ein FALSCHER Endstand als endgültig in der Antwort.

  test 'v1-Ticker nennt den richtigen Endstand, auch direkt nach dem Schlusspfiff' do
    @game.update!(ended: true)

    get "/api/v1/ticker/games/#{@game.id}", headers: header(@delayed_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert body['hasEnded']
    assert_equal '2:0', body['resultString'],
                 'Ein beendetes Spiel darf keinen Zwischenstand als Endstand melden'
  end

  test 'Spiel-Detail nennt den richtigen Endstand, auch direkt nach dem Schlusspfiff' do
    @game.update!(ended: true)

    get "/api/v2/games/#{@game.id}.json", headers: header(@delayed_key)

    assert_response :success
    assert_equal '2:0', JSON.parse(response.body)['result_string']
  end

  test 'ein nach dem Spiel getippter Bericht meldet nicht 0:0' do
    # Der Normalfall, nicht der Randfall: `added_at` ist der Zeitpunkt der
    # EINGABE. Wer den Bericht nach dem Schlusspfiff in einem Zug tippt, hat
    # ausschließlich frische Ereignisse. Ohne Ausnahme für beendete Spiele
    # fiele die Liste komplett weg und aus dem 3:0 würde ein gemeldetes 0:0.
    @game.update!(
      ended: true,
      events: [
        { 'row' => 1, 'period' => 1, 'time' => '05:00', 'home_number' => 7,
          'event_type' => 'goal', 'home_goals' => 1, 'guest_goals' => 0,
          'added_at' => 2.minutes.ago.to_i },
        { 'row' => 2, 'period' => 2, 'time' => '25:00', 'home_number' => 9,
          'event_type' => 'goal', 'home_goals' => 2, 'guest_goals' => 0,
          'added_at' => 1.minute.ago.to_i },
        { 'row' => 3, 'period' => 3, 'time' => '55:00', 'home_number' => 7,
          'event_type' => 'goal', 'home_goals' => 3, 'guest_goals' => 0,
          'added_at' => 30.seconds.ago.to_i }
      ]
    )

    get "/api/v1/ticker/games/#{@game.id}", headers: header(@delayed_key)

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal '3:0', body['resultString']
    assert_equal 3, body['events'].size
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

  test 'Team-Spielliste haelt auch ein Spiel ohne angelegten Bericht zurueck' do
    # Game#state kennt nur :no_record, solange record_created_at fehlt, das
    # Ergebnis hängt aber allein an started?. Wer auf den Status prüft, lässt
    # diesen Fall samt Live-Stand durch.
    @game.update!(record_created_at: nil)

    get "/api/v2/teams/#{@home.id}/matches", headers: header(@delayed_key)

    assert_response :success
    match = JSON.parse(response.body)['matches'].find { |m| m['game_id'] == @game.id }
    assert_nil match['result_string']
  end

  # ── Liga-Spielplan ────────────────────────────────────────────────────────
  # Der ursprüngliche und meistgenutzte Abnehmer von `delay_live_scores`, bis
  # hierher ohne Test.

  test 'Liga-Spielplan nimmt einem Zugang ohne Echtzeit das Ergebnis des laufenden Spiels' do
    get "/api/v2/leagues/#{@league.id}/schedule", headers: header(@delayed_key)

    assert_response :success
    entry = schedule_entry(JSON.parse(response.body))
    assert entry, 'Das Spiel muss im Spielplan stehen, nur ohne Ergebnis'
    assert_nil entry['result_string']
  end

  test 'Liga-Spielplan liefert einem Echtzeit-Zugang das Ergebnis' do
    get "/api/v2/leagues/#{@league.id}/schedule", headers: header(@realtime_raw)

    assert_response :success
    assert_equal '2:0', schedule_entry(JSON.parse(response.body))['result_string']
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
