require 'test_helper'

# Das Abgabefenster ist das spätere von zwei Ereignissen: Bericht-Abschluss und
# Anpfiff + FILLABLE_AFTER_HOURS. Beides muss erfüllt sein, sonst bleibt das
# Formular zu. Die Frist steht hier nirgends als Zahl: Tests, die auf eine noch
# laufende Sperre prüfen, frieren die Zeit relativ zur Konstante ein, damit ein
# geänderter Wert sie nicht abends kippen lässt.
class RefereeFeedbackWindowTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @club = create(:club)
  end

  test 'offener Spielbericht hat keinen Oeffnungszeitpunkt' do
    game = game_on(2.days.ago.to_date, status: 'pregame', closed_at: nil)

    window = RefereeFeedbackWindow.new(game)
    assert_nil window.opens_at
    assert_not window.open?
  end

  test 'direkt nach dem Spiel geschlossener Bericht oeffnet erst nach der Sperrfrist' do
    kickoff = local_time(match_today, '10:00')

    travel_to kickoff + (lock_period / 2) do
      game = game_on(match_today, start_time: '10:00', closed_at: Time.current)

      window = RefereeFeedbackWindow.new(game)
      assert_not window.open?
      assert_in_delta kickoff + lock_period, window.opens_at, 5.seconds
    end
  end

  # Die Frist selbst ist eine Absprache mit dem Schiedsrichterwesen: 12 Stunden
  # seit 09/2026, vorher 24. Deshalb hier festgenagelt und nicht nur relativ
  # geprüft — ein unbeabsichtigter Sprung soll auffallen.
  test 'die Sperrfrist betraegt zwoelf Stunden' do
    assert_equal 12, RefereeFeedbackWindow::FILLABLE_AFTER_HOURS
  end

  # Der Fall, um den es bei der Verkürzung geht: Samstagabend gespielt,
  # Sonntagmorgen beantwortet. Unter der alten 24-Stunden-Frist war das Fenster
  # zu diesem Zeitpunkt noch zu.
  test 'dreizehn Stunden nach Anpfiff ist das Fenster offen' do
    kickoff = RefereeFeedbackWindow::ZONE.now - 13.hours
    game = game_on(kickoff.to_date, start_time: kickoff.strftime('%H:%M'), closed_at: 1.hour.ago)

    assert RefereeFeedbackWindow.new(game).open?
  end

  test 'ist die Sperrfrist abgelaufen, zaehlt der Bericht-Abschluss' do
    closed_at = 1.hour.ago
    game = game_on(3.days.ago.to_date, start_time: '10:00', closed_at: closed_at)

    window = RefereeFeedbackWindow.new(game)
    assert window.open?
    assert_in_delta closed_at, window.opens_at, 5.seconds
  end

  test 'spaet geschlossener Bericht verschiebt die Oeffnung nach hinten' do
    closed_at = 2.hours.from_now
    game = game_on(3.days.ago.to_date, start_time: '10:00', closed_at: closed_at)

    window = RefereeFeedbackWindow.new(game)
    assert_not window.open?
    assert_in_delta closed_at, window.opens_at, 5.seconds
  end

  test 'ohne gepflegte Startzeit wird vom Tagesbeginn gerechnet' do
    day_start = local_time(match_today, '00:00')

    travel_to day_start + (lock_period / 2) do
      game = game_on(match_today, start_time: nil, closed_at: Time.current)

      window = RefereeFeedbackWindow.new(game)
      assert_not window.open?
      assert_in_delta day_start + lock_period, window.opens_at, 5.seconds
    end
  end

  # Ohne jeden verwertbaren Zeitpunkt bleibt der Bericht-Abschluss die einzige
  # Bedingung, damit Altspiele ohne Datum nicht dauerhaft gesperrt sind.
  test 'ohne Datum und ohne Abschlusszeitpunkt gilt allein der abgeschlossene Bericht' do
    game = game_on(match_today, closed_at: nil)
    game.game_day.update_columns(date: nil)
    game.reload

    window = RefereeFeedbackWindow.new(game)
    assert_nil window.opens_at
    assert window.open?
  end

  test 'unparsebares Spieltagsdatum sperrt nicht dauerhaft' do
    game = game_on(match_today, closed_at: nil)
    game.game_day.update_columns(date: 'kein Datum')
    game.reload

    assert RefereeFeedbackWindow.new(game).open?
  end

  # Die Anwendung läuft in UTC, Spieltagsdaten sind deutsche Daten. Abends
  # zwischen 22:00 und 24:00 UTC liegen die beiden Kalender einen Tag
  # auseinander, und genau in diesem Fenster hat die Suite früher fünf Tests
  # verloren. Die feste Uhrzeit hält den Fall dauerhaft nach, statt ihn nur
  # abends zufällig zu treffen.
  test 'das Fenster rechnet auch spaetabends mit dem deutschen Kalender' do
    travel_to ActiveSupport::TimeZone['Europe/Berlin'].parse('2026-08-07 00:30') do
      # 22:30 UTC am 6.8., aber in der Halle ist bereits der 7.8.
      assert_equal Date.new(2026, 8, 7), RefereeFeedbackWindow.today
      assert_equal Date.new(2026, 8, 6), Date.current, 'Vorbedingung: die Anwendung liegt in UTC'

      game = game_on(RefereeFeedbackWindow.today, start_time: '10:00', closed_at: Time.current)

      window = RefereeFeedbackWindow.new(game)
      assert_not window.open?, 'Ein Spiel von heute Vormittag hat um 00:30 noch nicht angefangen'
      assert_in_delta local_time('2026-08-07', '10:00') + lock_period, window.opens_at, 5.seconds
    end
  end

  private

  def game_on(date, start_time: '10:00', status: 'match_record_closed', closed_at: Time.current)
    game_day = create(:game_day, league: @league, club: @club, date: date.to_s)
    create(:game,
           game_day: game_day,
           start_time: start_time,
           game_status: status,
           match_record_closed_at: closed_at)
  end

  # Kalender des Spielbetriebs, nicht der der Anwendung. Ohne das baut ein
  # Lauf zwischen 22:00 und 24:00 UTC ein Spiel von gestern, und die Tests
  # oben warten vergeblich auf ein noch geschlossenes Fenster.
  def match_today
    RefereeFeedbackWindow.today
  end

  def lock_period
    RefereeFeedbackWindow::FILLABLE_AFTER_HOURS.hours
  end

  def local_time(date, time)
    RefereeFeedbackWindow::ZONE.parse("#{date} #{time}")
  end
end
