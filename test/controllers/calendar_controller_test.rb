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

  private

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
