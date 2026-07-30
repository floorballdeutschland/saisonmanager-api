require 'test_helper'

# Das Abgabefenster ist das spätere von zwei Ereignissen: Bericht-Abschluss und
# Anpfiff + 24 h. Beides muss erfüllt sein, sonst bleibt das Formular zu.
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

  test 'direkt nach dem Spiel geschlossener Bericht oeffnet erst 24 Stunden nach Anpfiff' do
    game = game_on(Date.current, start_time: '10:00', closed_at: Time.current)

    window = RefereeFeedbackWindow.new(game)
    assert_not window.open?
    assert_in_delta local_time(Date.current, '10:00') + 24.hours, window.opens_at, 5.seconds
  end

  test 'liegt das Spiel mehr als 24 Stunden zurueck, zaehlt der Bericht-Abschluss' do
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
    game = game_on(Date.current, start_time: nil, closed_at: Time.current)

    window = RefereeFeedbackWindow.new(game)
    assert_not window.open?
    assert_in_delta local_time(Date.current, '00:00') + 24.hours, window.opens_at, 5.seconds
  end

  # Ohne jeden verwertbaren Zeitpunkt bleibt der Bericht-Abschluss die einzige
  # Bedingung, damit Altspiele ohne Datum nicht dauerhaft gesperrt sind.
  test 'ohne Datum und ohne Abschlusszeitpunkt gilt allein der abgeschlossene Bericht' do
    game = game_on(Date.current, closed_at: nil)
    game.game_day.update_columns(date: nil)
    game.reload

    window = RefereeFeedbackWindow.new(game)
    assert_nil window.opens_at
    assert window.open?
  end

  test 'unparsebares Spieltagsdatum sperrt nicht dauerhaft' do
    game = game_on(Date.current, closed_at: nil)
    game.game_day.update_columns(date: 'kein Datum')
    game.reload

    assert RefereeFeedbackWindow.new(game).open?
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

  def local_time(date, time)
    ActiveSupport::TimeZone['Europe/Berlin'].parse("#{date} #{time}")
  end
end
