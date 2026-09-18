require 'test_helper'

# Das Bestätigungsfenster der Gastmannschaften zählt ab dem SPÄTEREN von zwei
# Zeitpunkten: dem Ende des Spieltags und der Benachrichtigung. Vorher zählte
# allein das Spieltagsende – die Mail geht aber erst beim Abschluss des
# Spielberichts raus, sodass ein spät geschlossener Bericht eine Frist ankündigte,
# die bereits abgelaufen war.
class GameDayTeamConfirmationWindowTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league)
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: create(:club),
                                number: 1, date: '2026-09-13')
    @spieltagsende = Date.parse('2026-09-13').to_datetime.end_of_day.to_time
  end

  test 'ohne Benachrichtigung zaehlt das Ende des Spieltags' do
    assert_in_delta @spieltagsende + 48.hours, @game_day.team_confirmation_deadline, 1.second
  end

  test 'eine Benachrichtigung am Spieltag verkuerzt die Frist nicht' do
    @game_day.update!(team_confirmation_notified_at: Time.utc(2026, 9, 13, 16, 14))

    assert_in_delta @spieltagsende + 48.hours, @game_day.team_confirmation_deadline, 1.second
  end

  test 'eine spaetere Benachrichtigung verschiebt die Frist' do
    spaeter = Time.utc(2026, 9, 18, 10, 0)
    @game_day.update!(team_confirmation_notified_at: spaeter)

    assert_in_delta spaeter + 48.hours, @game_day.team_confirmation_deadline, 1.second
  end

  test 'ohne Datum und ohne Benachrichtigung gibt es keine Frist' do
    @game_day.update_columns(date: nil)

    assert_nil @game_day.reload.team_confirmation_deadline
  end

  test 'ein unlesbares Datum wirft, statt still keine Frist zu liefern' do
    # `game_days.date` ist eine Textspalte, und die Validierung greift nur, wenn
    # das Datum angefasst wird – im Bestand liegen also auch unlesbare Werte. Ein
    # stilles nil wäre hier „keine Frist" und damit „nie automatisch bestätigt".
    # Die Aufrufer sollen den Datenfehler sehen und protokollieren.
    @game_day.update_columns(date: 'kein Datum')

    assert_raises(Date::Error) { @game_day.reload.team_confirmation_deadline }
  end
end
