require 'test_helper'

# Kampflose Wertung mit von Hand festgesetztem Ergebnis.
#
# Bis hierher stand das Ergebnis eines Forfait-Spiels fest: League#forfait_goals
# (5 bzw. 8) gegen 0. Die Spielordnung kennt aber Faelle, in denen die SBK ein
# abweichendes Ergebnis festsetzt -- etwa wenn das Spiel ausgetragen wurde und
# das erzielte Ergebnis zugunsten der nicht schuldigen Mannschaft bestehen
# bleibt.
class GameForfaitResultTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league)
    @game_day = create(:game_day, league: @league)
  end

  def forfait_game(attrs = {})
    create(:game, { game_day: @game_day, started: true, ended: true }.merge(attrs))
  end

  test 'ohne Festsetzung gilt weiter die Liga-Vorgabe' do
    game = forfait_game(forfait: 1)

    assert_equal 0, game.result[:home_goals]
    assert_equal @league.forfait_goals, game.result[:guest_goals]
  end

  test 'ein festgesetztes Ergebnis schlaegt die Liga-Vorgabe' do
    game = forfait_game(forfait: 1, forfait_home_goals: 2, forfait_guest_goals: 9)

    assert_equal 2, game.result[:home_goals]
    assert_equal 9, game.result[:guest_goals]
    assert game.result[:forfait]
  end

  # Die beidseitige Wertung setzt ohne Festsetzung negative Tore, damit sie das
  # Torverhaeltnis belastet. Ein festgesetztes Ergebnis gilt dagegen so, wie es
  # eingetragen wurde -- sonst kaeme aus einer Eingabe von 0:0 ein -0:-0 und aus
  # 1:1 ein -1:-1.
  test 'beidseitige Wertung uebernimmt das festgesetzte Ergebnis unveraendert' do
    game = forfait_game(forfait: 3, forfait_home_goals: 0, forfait_guest_goals: 0)

    assert_equal 0, game.result[:home_goals]
    assert_equal 0, game.result[:guest_goals]
  end

  test 'beidseitige Wertung ohne Festsetzung bleibt bei den negativen Vorgabetoren' do
    game = forfait_game(forfait: 3)

    assert_equal(-@league.forfait_goals, game.result[:home_goals])
    assert_equal(-@league.forfait_goals, game.result[:guest_goals])
  end

  # Ein halbes Ergebnis waere kein Ergebnis: die fehlende Seite kaeme aus der
  # Liga-Vorgabe und ergaebe eine Mischung, die niemand beschlossen hat.
  test 'nur eine Torzahl wird abgewiesen' do
    game = build(:game, game_day: @game_day, forfait: 1, forfait_home_goals: 3)

    assert_not game.valid?
    assert_includes game.errors[:base].join, 'beide Torzahlen'
  end

  test 'negative Torzahlen werden abgewiesen' do
    game = build(:game, game_day: @game_day, forfait: 1,
                        forfait_home_goals: -1, forfait_guest_goals: 5)

    assert_not game.valid?
  end

  # Der Ruecksprung auf die regulaere Wertung muss das festgesetzte Ergebnis
  # mitnehmen. Bliebe es stehen, wuerde es bei der naechsten kampflosen Wertung
  # ungefragt wieder gelten, ohne dass es irgendwo sichtbar waere.
  test 'regulaere Wertung raeumt ein festgesetztes Ergebnis ab' do
    game = forfait_game(forfait: 1, forfait_home_goals: 2, forfait_guest_goals: 9)

    game.update!(forfait: 0)

    assert_nil game.reload.forfait_home_goals
    assert_nil game.forfait_guest_goals
  end

  # Die Tabelle rechnet ueber Game#result. Ein festgesetztes Ergebnis muss also
  # bis in Tore und Punkte durchschlagen und nicht nur auf der Spielseite stehen.
  test 'die Tabelle rechnet mit dem festgesetzten Ergebnis' do
    club = create(:club)
    home = create(:team, league: @league, club:)
    guest = create(:team, league: @league, club:)
    forfait_game(forfait: 1, forfait_home_goals: 2, forfait_guest_goals: 9,
                 home_team: home, guest_team: guest)

    row = @league.table.find { |item| item[:team_id] == home.id }

    assert_equal 2, row[:goals_scored]
    assert_equal 9, row[:goals_received]
  end

  # Die beidseitige Wertung gibt keiner Mannschaft Punkte -- das entscheidet die
  # Wertungsart und nicht die Torzahl. Bis hierher konnte sie gar nicht anders
  # enden als unentschieden (die Vorgabe ergibt -8:-8), und der Riegel gegen die
  # Punktvergabe hing genau daran. Mit einem festgesetzten Ergebnis kann sie
  # ungleich ausgehen, und dann liefe sie ohne diesen Test in den Sieg-Zweig der
  # Tabelle samt voller Punktzahl.
  test 'beidseitige Wertung mit ungleichem Ergebnis gibt keine Punkte' do
    club = create(:club)
    home = create(:team, league: @league, club:)
    guest = create(:team, league: @league, club:)
    forfait_game(forfait: 3, forfait_home_goals: 5, forfait_guest_goals: 3,
                 home_team: home, guest_team: guest)

    tabelle = @league.table
    heim = tabelle.find { |item| item[:team_id] == home.id }
    gast = tabelle.find { |item| item[:team_id] == guest.id }

    assert_equal 0, heim[:points], 'die kampflos gewertete Siegerin bekommt keine Punkte'
    assert_equal 0, gast[:points]
    assert_equal 5, heim[:goals_scored], 'das festgesetzte Ergebnis zaehlt trotzdem'
    assert_equal 3, heim[:goals_received]
  end

  # Gegenprobe zum Umbau: Der bisherige Fall (kein festgesetztes Ergebnis, also
  # -8:-8 und damit unentschieden) bleibt ebenfalls ohne Punkte.
  test 'beidseitige Wertung ohne Festsetzung gibt weiterhin keine Punkte' do
    club = create(:club)
    home = create(:team, league: @league, club:)
    guest = create(:team, league: @league, club:)
    forfait_game(forfait: 3, home_team: home, guest_team: guest)

    tabelle = @league.table

    assert_equal 0, tabelle.find { |item| item[:team_id] == home.id }[:points]
    assert_equal 0, tabelle.find { |item| item[:team_id] == guest.id }[:points]
  end

  # Und die einseitige Wertung vergibt weiter Punkte: Der Riegel darf nur die
  # beidseitige treffen.
  test 'einseitige Wertung vergibt weiterhin Punkte' do
    club = create(:club)
    home = create(:team, league: @league, club:)
    guest = create(:team, league: @league, club:)
    forfait_game(forfait: 1, home_team: home, guest_team: guest)

    gast = @league.table.find { |item| item[:team_id] == guest.id }

    assert_equal @league.won_points, gast[:points]
  end
end
