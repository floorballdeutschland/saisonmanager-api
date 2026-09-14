require 'test_helper'

# `Game#result_string` ist die kurze Ergebnisdarstellung der API. Sie steht
# ueberall dort, wo die Anzeige nicht den vollen `result`-Hash auswertet --
# Live-Ansicht, Ergebnisspalte der Spielberichtsuebersicht, Spielplan-Eintraege.
#
# Der Zusatz aus `result_postfix` hing bis hierher an `overtime`. Damit fiel
# ausgerechnet der Fall weg, den `result_postfix` als ERSTEN prueft: Bei einer
# kampflos gewerteten Partie ist `overtime` false, also stand dort ein glattes
# „0:5" -- ein Ergebnis, das so nicht gespielt wurde.
class GameResultStringTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league)
    @game_day = create(:game_day, league: @league)
  end

  def game(attrs = {})
    create(:game, { game_day: @game_day, started: true, ended: true }.merge(attrs))
  end

  def tor(period, home, guest, row)
    { 'id' => row, 'row' => row, 'period' => period, 'time' => '1:00', 'event_type' => 'goal',
      'event_team' => home > guest ? 'home' : 'guest', 'home_goals' => home, 'guest_goals' => guest }
  end

  test 'kampflose Wertung traegt den Zusatz' do
    assert_equal "0:#{@league.forfait_goals} (forfait)", game(forfait: 1).result_string
  end

  test 'kampflose Wertung mit festgesetztem Ergebnis traegt ihn auch' do
    g = game(forfait: 1, forfait_home_goals: 2, forfait_guest_goals: 9)

    assert_equal '2:9 (forfait)', g.result_string
  end

  test 'beidseitige Wertung traegt ihn ebenfalls' do
    v = @league.forfait_goals

    assert_equal "-#{v}:-#{v} (forfait)", game(forfait: 3).result_string
  end

  # Genau ein Leerzeichen. Der Forfait-Zusatz bringt selbst eines mit, die
  # Verlaengerungs-Zusaetze nicht -- ungestrippt kaeme „0:5  (forfait)" heraus.
  test 'zwischen Ergebnis und Zusatz steht genau ein Leerzeichen' do
    assert_no_match(/\s{2}/, game(forfait: 1).result_string)
  end

  test 'ein regulaeres Ergebnis bleibt ohne Zusatz und ohne Leerzeichen am Ende' do
    g = game(events: [tor(1, 1, 0, 1), tor(2, 2, 1, 2)])

    assert_equal '2:1', g.result_string
  end

  # Gegenprobe: Der bisherige Zweck der Zeile bleibt erhalten.
  test 'nach Verlaengerung steht weiterhin n.V.' do
    g = game(overtime: true, events: [tor(1, 1, 0, 1), tor(3, 2, 1, 2)])

    assert_equal '2:1 n.V.', g.result_string
  end

  test 'ohne Ergebnis kommt nichts heraus' do
    assert_nil game(started: false, ended: false).result_string
  end
end
