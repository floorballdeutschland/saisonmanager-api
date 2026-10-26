require 'test_helper'

# Spielstärke bei Schüssen ohne eigenen Torhüter aus den laufenden Strafen
# (fe#610). Heim schießt, wenn nicht anders angegeben.
class GameShotStrengthTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go, periods: 3, period_length: 20)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-10-11')
    @game = Game.create!(game_day: @game_day,
                         home_team: create(:team, league: @league, club: @club),
                         guest_team: create(:team, league: @league, club: create(:club)),
                         forfait: 0, overtime: false, legacy: false, events: [],
                         players: { 'home' => [], 'guest' => [] })
    @next_id = 0
  end

  test 'ohne laufende Strafe 6 gegen 5' do
    assert_equal '6v5', staerke([], schuss('5:00'))
  end

  test 'ohne Kennung oder ohne Spielzeit keine Stärke' do
    assert_nil staerke([], schuss('5:00', extra_attacker: false))
    assert_nil staerke([strafe('guest', '4:00')], schuss(nil))
    assert_nil staerke([strafe('guest', '4:00')], schuss('vier'))
  end

  test 'Torwart raus in Überzahl ist 6 gegen 4, mit zwei Strafen 6 gegen 3' do
    assert_equal '6v4', staerke([strafe('guest', '4:00')], schuss('5:00'))
    assert_equal '6v3', staerke([strafe('guest', '4:00'), strafe('guest', '4:30')], schuss('5:00'))
    assert_equal '6v3', staerke([strafe('guest', '4:00'), strafe('guest', '4:10'), strafe('guest', '4:20')],
                                schuss('5:00')), 'mehr als zwei Feldspieler weniger gibt es nicht'
  end

  test 'abgelaufene Strafe zählt nicht, die Grenze ist das Ende' do
    assert_equal '6v5', staerke([strafe('guest', '4:00')], schuss('6:00'))
    assert_equal '6v4', staerke([strafe('guest', '4:00')], schuss('5:59'))
  end

  test 'eine Strafe in derselben Sekunde läuft noch nicht (angezeigte Strafe)' do
    assert_equal '6v5', staerke([strafe('guest', '5:00')], schuss('5:00'))
  end

  test 'eigene Strafe: das schießende Team ist selbst in Unterzahl' do
    assert_equal '5v5', staerke([strafe('home', '4:00')], schuss('5:00'))
    assert_equal '4v5', staerke([strafe('home', '4:00'), strafe('home', '4:30')], schuss('5:00'))
  end

  test 'Strafen beider Teams heben sich nicht auf, gezählt wird, was auf dem Feld steht' do
    assert_equal '5v4', staerke([strafe('home', '4:00'), strafe('guest', '4:00')], schuss('5:00'))
    assert_equal '5v3', staerke([strafe('home', '4:00'), strafe('guest', '4:00'), strafe('guest', '4:30')],
                                schuss('5:00'))
    assert_equal '4v4', staerke([strafe('home', '4:00'), strafe('home', '4:10'), strafe('guest', '4:20')],
                                schuss('5:00'))
  end

  test 'ein Überzahltor beendet die kleine Strafe' do
    assert_equal '6v5', staerke([strafe('guest', '4:00'), tor('home', '4:30')], schuss('5:00'))
  end

  test 'ein Tor bei gleicher Zahl beendet keine Strafe' do
    ereignisse = [strafe('home', '4:00'), strafe('guest', '4:00'), tor('home', '4:20'), strafe('guest', '4:40')]

    assert_equal '5v3', staerke(ereignisse, schuss('5:00'))
  end

  test 'ein Überzahltor beendet nur die Strafe, die als nächste abliefe' do
    ereignisse = [strafe('guest', '4:00'), strafe('guest', '4:30'), tor('home', '5:00')]

    assert_equal '6v4', staerke(ereignisse, schuss('5:10'))
    assert_equal '6v5', staerke(ereignisse, schuss('6:40'))
  end

  test 'das Gegentor des Strafteams selbst beendet nichts' do
    assert_equal '6v4', staerke([strafe('guest', '4:00'), tor('guest', '4:30')], schuss('5:00'))
  end

  test 'doppelte kleine Strafe: das Tor beendet die erste Hälfte, die zweite läuft ab dem Tor' do
    ereignisse = [strafe('guest', '4:00', 'penalty_2and2'), tor('home', '4:30')]

    assert_equal '6v4', staerke(ereignisse, schuss('6:20'))
    assert_equal '6v5', staerke(ereignisse, schuss('6:40'))
  end

  test 'fünf Minuten enden nicht beim Tor, zehn Minuten bringen keine Unterzahl' do
    assert_equal '6v4', staerke([strafe('guest', '4:00', 'penalty_5'), tor('home', '4:30')], schuss('8:00'))
    assert_equal '6v5', staerke([strafe('guest', '4:00', 'penalty_10')], schuss('5:00'))
  end

  test 'jede Matchstrafe zählt wie eine Bankstrafe 2+2, auch ohne eingetragene' do
    %w[penalty_ms_full penalty_ms_tech penalty_ms1 penalty_ms2 penalty_ms3].each do |mapping|
      assert_equal '6v4', staerke([strafe('guest', '4:00', mapping)], schuss('7:59')), mapping
      assert_equal '6v5', staerke([strafe('guest', '4:00', mapping)], schuss('8:00')), mapping
    end
  end

  test 'Matchstrafe endet wie 2+2: das Überzahltor beendet die erste Hälfte' do
    ereignisse = [strafe('guest', '4:00', 'penalty_ms_full'), tor('home', '4:30')]

    assert_equal '6v4', staerke(ereignisse, schuss('6:20'))
    assert_equal '6v5', staerke(ereignisse, schuss('6:40'))
  end

  test 'eingetragene Bankstrafe zur selben Zeit zählt nicht doppelt' do
    mit_bankstrafe = [strafe('guest', '4:00', 'penalty_ms_full'), strafe('guest', '4:00', 'penalty_2and2')]
    assert_equal '6v4', staerke(mit_bankstrafe, schuss('5:00'))

    altdaten = [strafe('guest', '4:00', 'penalty_ms2'), strafe('guest', '4:00', 'penalty_5')]
    assert_equal '6v4', staerke(altdaten, schuss('5:00'))
    assert_equal '6v4', staerke(altdaten, schuss('8:30')), 'die eingetragenen fünf Minuten laufen ganz ab'

    andere_zeit = [strafe('guest', '4:00', 'penalty_ms_full'), strafe('guest', '4:30', 'penalty_2and2')]
    assert_equal '6v3', staerke(andere_zeit, schuss('5:00'))

    anderes_team = [strafe('guest', '4:00', 'penalty_ms_full'), strafe('home', '4:00', 'penalty_2and2')]
    assert_equal '5v4', staerke(anderes_team, schuss('5:00'))

    zwei_minuten = [strafe('guest', '4:00', 'penalty_ms_full'), strafe('guest', '4:00', 'penalty_2')]
    assert_equal '6v3', staerke(zwei_minuten, schuss('5:00')), 'eine kleine Strafe ist nicht die Bankstrafe'
  end

  test 'das Tor des Schusses selbst beendet die Strafe nicht vorher' do
    ereignisse = [strafe('guest', '4:00'), tor('home', '5:00')]
    verknuepft = schuss(nil, event_id: ereignisse.last['id'])

    assert_equal '6v4', staerke(ereignisse, verknuepft)
  end

  test 'am verknüpften Tor zählt dessen Zeit, nicht die am Schuss' do
    ereignisse = [strafe('guest', '4:00'), tor('home', '5:00')]

    assert_equal '6v4', staerke(ereignisse, schuss('9:00', event_id: ereignisse.last['id']))
  end

  test 'mit Abschnittslänge läuft eine Strafe in den nächsten Abschnitt hinüber' do
    ereignisse = [strafe('guest', '19:30', 'penalty_2', period: 1)]

    assert_equal '6v4', staerke(ereignisse, schuss('1:00', period: 2))
    assert_equal '6v5', staerke(ereignisse, schuss('1:30', period: 2))
  end

  test 'durchgehend erfasste Zeit im späteren Abschnitt bleibt stehen' do
    ereignisse = [strafe('guest', '24:00', 'penalty_2', period: 2)]

    assert_equal '6v4', staerke(ereignisse, schuss('5:00', period: 2))
  end

  test 'ohne Abschnittslänge zählt nur der Abschnitt des Schusses' do
    @league.update!(period_length: nil)
    ereignisse = [strafe('guest', '19:30', 'penalty_2', period: 1)]

    assert_equal '6v5', staerke(ereignisse, schuss('1:00', period: 2))
    assert_equal '6v4', staerke([strafe('guest', '0:30', 'penalty_2', period: 2)], schuss('1:00', period: 2))
  end

  test 'Gruppen für die Summen' do
    assert_equal '6v5', GameShotStrength.bucket('6v5')
    assert_equal '6v4', GameShotStrength.bucket('6v4')
    assert_equal 'other', GameShotStrength.bucket('6v3')
    assert_equal 'other', GameShotStrength.bucket('5v4')
    assert_equal 'other', GameShotStrength.bucket('4v5')
    assert_equal 'unknown', GameShotStrength.bucket(nil)
  end

  private

  def staerke(ereignisse, shot)
    @game.update!(events: ereignisse)
    GameShotStrength.new(@game.reload).for(shot)
  end

  def schuss(game_time, team: 'home', period: 1, extra_attacker: true, event_id: nil)
    GameShot.new(game: @game, kind: 'shot', team: team, period: period, game_time: game_time, result: 'goal',
                 extra_attacker: extra_attacker, event_id: event_id)
  end

  def strafe(team, time, mapping = 'penalty_2', period: 1)
    { 'id' => (@next_id += 1), 'period' => period, 'time' => time, 'event_team' => team, "#{team}_number" => 4,
      'penalty_id' => '1', 'penalty_code_id' => '1', 'penalty_mapping' => mapping }
  end

  def tor(team, time, period: 1)
    { 'id' => (@next_id += 1), 'period' => period, 'time' => time, 'event_team' => team, "#{team}_number" => 7 }
  end
end
