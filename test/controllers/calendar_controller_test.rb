require 'test_helper'

# Kalender-Abos (ICS) für Mannschaft, Liga und Einzelspiel.
#
# Die verlinkten Adressen waren nie erreichbar: Sie lagen auf Wurzelebene
# (`/calendar/...`), und nginx reicht nur /api und /verband an Rails weiter.
# Zusätzlich verlangte der ICS-Weg einen X-Api-Key, den kein Kalender-Programm
# mitschicken kann. Beide Hälften prüft dieser Test, sonst sieht ein Abo auch
# nach dem Fix nur scheinbar behoben aus.
class CalendarControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
  end

  test 'ein Mannschaftskalender kommt ohne API-Key' do
    game = game_with(start_time: '14:00')

    get "/api/v2/calendar/teams/#{@home.id}.ics"

    assert_response :success
    assert_includes response.body, 'BEGIN:VCALENDAR'
    assert_includes response.body, "sm_game_#{game.id}"
  end

  # Kalender-Programme entscheiden am Content-Type, ob sie ein Abo annehmen.
  # `render plain:` allein schickte text/plain.
  test 'der Kalender wird als text/calendar ausgeliefert' do
    game_with(start_time: '14:00')

    get "/api/v2/calendar/teams/#{@home.id}.ics"

    assert_response :success
    assert_equal 'text/calendar', response.media_type
  end

  # Manche Kalender-Programme lassen die Endung weg und fragen mit Accept: */*.
  test 'ein Abo ohne .ics-Endung bekommt ebenfalls einen Kalender' do
    game_with(start_time: '14:00')

    get "/api/v2/calendar/teams/#{@home.id}"

    assert_response :success
    assert_includes response.body, 'BEGIN:VCALENDAR'
  end

  test 'Liga- und Spielkalender kommen ohne API-Key' do
    game = game_with(start_time: '14:00')

    get "/api/v2/calendar/leagues/#{@league.id}.ics"
    assert_response :success
    assert_includes response.body, "sm_game_#{game.id}"

    get "/api/v2/calendar/games/#{game.id}.ics"
    assert_response :success
    assert_includes response.body, "sm_game_#{game.id}"
  end

  # Vorher HTTP 500 (Sentry SAISONMANAGER-29): `events.first.dtstart` auf einer
  # leeren Liste. Betraf jede Mannschaft ohne Termine, am Saisonanfang also alle.
  test 'eine Mannschaft ohne Spiele liefert einen leeren Kalender statt 500' do
    get "/api/v2/calendar/teams/#{@home.id}.ics"

    assert_response :success
    assert_includes response.body, 'BEGIN:VCALENDAR'
    assert_not_includes response.body, 'BEGIN:VEVENT'
  end

  # Ein Spiel ohne Anpfiffzeit hat kein dtstart (Game#start_date ist nil, wenn
  # Datum oder Startzeit fehlen). Es darf den Kalender nicht kippen und gehört
  # auch nicht als Termin ohne Zeitpunkt hinein.
  test 'ein Spiel ohne Anpfiffzeit fällt aus dem Kalender statt ihn zu kippen' do
    ohne_zeit = game_with(start_time: nil)

    get "/api/v2/calendar/teams/#{@home.id}.ics"

    assert_response :success
    assert_not_includes response.body, "sm_game_#{ohne_zeit.id}"
    assert_not_includes response.body, 'BEGIN:VEVENT'
  end

  test 'ein Spiel mit Zeit bleibt neben einem Spiel ohne Zeit im Kalender' do
    mit_zeit = game_with(start_time: '14:00')
    ohne_zeit = game_with(start_time: nil, number: 2)

    get "/api/v2/calendar/teams/#{@home.id}.ics"

    assert_response :success
    assert_includes response.body, "sm_game_#{mit_zeit.id}"
    assert_not_includes response.body, "sm_game_#{ohne_zeit.id}"
  end

  # Gegenprobe zum Key-Verzicht: Er gilt nur für die Kalender-Actions. Die
  # JSON-Endpunkte derselben Controller müssen weiter einen Key verlangen, sonst
  # hätte der Fix die öffentliche API nebenbei geöffnet.
  test 'der Key-Verzicht gilt nicht für die JSON-Endpunkte' do
    game = game_with(start_time: '14:00')

    get "/api/v2/leagues/#{@league.id}.json"
    assert_response :unauthorized

    get "/api/v2/games/#{game.id}.json"
    assert_response :unauthorized

    get "/api/v2/teams/#{@home.id}/stats.json"
    assert_response :unauthorized
  end

  # Der Endpunkt verlangt keinen API-Schlüssel, es gibt also keine Grenze je
  # Schlüssel, die den Aufwand deckelt. Der Cache-Header ist damit die einzige
  # Bremse gegen wiederholte Abrufe desselben Abos.
  test 'der Kalender ist eine Stunde öffentlich cachebar' do
    game_with(start_time: '14:00')

    get "/api/v2/calendar/teams/#{@home.id}.ics"

    assert_response :success
    assert_match(/max-age=3600/, response.headers['Cache-Control'])
    assert_match(/public/, response.headers['Cache-Control'])
  end

  # Ein Kalender-Abo läuft unbeaufsichtigt und ohne API-Schlüssel: Kalender-
  # Programme fragen von selbst regelmäßig nach. Ohne Preloading kostet jedes
  # Spiel rund sechs Abfragen (Spieltag, Halle, Liga, Spielbetrieb, zwei
  # Mannschaften). Der Test hält fest, dass mehr Spiele die Abfragezahl nicht
  # mitwachsen lassen — sonst schleicht sich genau das N+1 zurück, das im
  # Spielplan rund 70.000 Meldungen erzeugt hat.
  test 'die Abfragezahl wächst nicht mit der Anzahl der Spiele' do
    game_with(start_time: '14:00')
    queries_for_one = count_queries { get "/api/v2/calendar/teams/#{@home.id}.ics" }
    assert_response :success

    4.times { |i| game_with(start_time: '16:00', number: i + 2) }
    queries_for_five = count_queries { get "/api/v2/calendar/teams/#{@home.id}.ics" }

    assert_response :success
    assert_equal 5, response.body.scan('BEGIN:VEVENT').size
    assert_equal queries_for_one, queries_for_five,
                 "Abfragen: #{queries_for_one} bei einem Spiel, #{queries_for_five} bei fünf — Preloading fehlt"
  end

  # Der Preload muss an allen drei Kalender-Pfaden hängen, nicht nur an zweien.
  # Beim ersten Anlauf fehlte er ausgerechnet am Einzelspiel, weil die Änderung
  # nicht mit committet wurde – ein Test, der nur den Mannschaftskalender misst,
  # hätte das durchgelassen.
  test 'auch Liga- und Spielkalender laden ihre Assoziationen vor' do
    game = game_with(start_time: '14:00')
    4.times { |i| game_with(start_time: '16:00', number: i + 2) }

    liga_queries = count_queries { get "/api/v2/calendar/leagues/#{@league.id}.ics" }
    assert_response :success
    assert_equal 5, response.body.scan('BEGIN:VEVENT').size

    einzel_queries = count_queries { get "/api/v2/calendar/games/#{game.id}.ics" }
    assert_response :success

    # Fünf Spiele über wenige vorgeladene Abfragen; ohne Preload wären es rund
    # sechs je Spiel. Die Grenze ist bewusst grob, geprüft wird die
    # Größenordnung, nicht eine exakte Zahl.
    assert_operator liga_queries, :<, 15, "Liga-Kalender: #{liga_queries} Abfragen, Preloading fehlt"
    assert_operator einzel_queries, :<, 10, "Spiel-Kalender: #{einzel_queries} Abfragen, Preloading fehlt"
  end

  private

  def count_queries(&block)
    count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      count += 1 unless payload[:name] == 'SCHEMA' || payload[:sql].start_with?('BEGIN', 'COMMIT', 'ROLLBACK')
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
    count
  end

  def game_with(start_time:, number: 1)
    game_day = GameDay.create!(
      league: @league, arena: create(:arena), club: @club, number:, date: '2026-09-05'
    )
    Game.create!(
      game_day:, home_team: @home, guest_team: @guest, start_time:,
      started: false, ended: false, forfait: 0, overtime: false, legacy: false,
      events: [], players: { 'home' => [], 'guest' => [] }
    )
  end
end
