require 'test_helper'

class GameTest < ActiveSupport::TestCase
  def build_game(attrs = {})
    Game.new({
      started: true,
      overtime: false,
      forfait: 0,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    }.merge(attrs))
  end

  def mock_league(attrs = {})
    OpenStruct.new({
      period_count_normal_game: 2,
      period_penalty_shots: 4,
      forfait_goals: 8
    }.merge(attrs))
  end

  # ---------------------------------------------------------------------------
  # result
  # ---------------------------------------------------------------------------

  test 'result: kein Spiel ohne started' do
    g = build_game(started: false)
    assert_nil g.result
  end

  test 'result: gestartetes Spiel ohne Events ergibt 0:0' do
    g = build_game(started: true, events: [])
    r = g.result
    assert_equal 0, r[:home_goals].to_i
    assert_equal 0, r[:guest_goals].to_i
    assert_not r[:forfait]
    assert_not r[:overtime]
  end

  test 'result: Events werden korrekt summiert' do
    events = [
      { 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 },
      { 'period' => 1, 'home_goals' => 2, 'guest_goals' => 0, 'row' => 2 },
      { 'period' => 2, 'home_goals' => 2, 'guest_goals' => 1, 'row' => 3 }
    ]
    g = build_game(events: events)
    r = g.result
    assert_equal 2, r[:home_goals].to_i
    assert_equal 1, r[:guest_goals].to_i
  end

  test 'result: Perioden-Tore werden pro Periode aufgeteilt' do
    events = [
      { 'period' => 1, 'home_goals' => 2, 'guest_goals' => 0, 'row' => 1 },
      { 'period' => 2, 'home_goals' => 3, 'guest_goals' => 1, 'row' => 2 }
    ]
    g = build_game(events: events)
    r = g.result
    # 2 goals in P1, 1 more in P2 → [2, 1, 0, 0]
    assert_equal 2, r[:home_goals_period][0]
    assert_equal 1, r[:home_goals_period][1]
  end

  test 'result: Forfait 1 (Heim verliert) mit league.forfait_goals' do
    g = build_game(forfait: 1)
    g.stub(:league, mock_league(forfait_goals: 5)) do
      r = g.result
      assert_equal 0, r[:home_goals].to_i
      assert_equal 5, r[:guest_goals].to_i
      assert r[:forfait]
    end
  end

  test 'result: Forfait 2 (Gast verliert) mit league.forfait_goals' do
    g = build_game(forfait: 2)
    g.stub(:league, mock_league(forfait_goals: 8)) do
      r = g.result
      assert_equal 8, r[:home_goals].to_i
      assert_equal 0, r[:guest_goals].to_i
    end
  end

  # ---------------------------------------------------------------------------
  # extract_timeout_information
  # ---------------------------------------------------------------------------

  test 'extract_timeout_information: Format "16:22 / III"' do
    g = build_game
    info = g.extract_timeout_information('16:22 / III', 'home')
    assert_equal '16:22', info[:time]
    assert_equal 3, info[:period]
    assert_equal 'home', info[:event_team]
    assert_equal 'timeout', info[:event_type]
  end

  test 'extract_timeout_information: Format "III 8:50"' do
    g = build_game
    info = g.extract_timeout_information('III 8:50', 'guest')
    assert_equal '8:50', info[:time]
    assert_equal 3, info[:period]
    assert_equal 'guest', info[:event_team]
  end

  test 'extract_timeout_information: Format "12:42/I"' do
    g = build_game
    info = g.extract_timeout_information('12:42/I', 'home')
    assert_equal '12:42', info[:time]
    assert_equal 1, info[:period]
  end

  test 'extract_timeout_information: Format "19:01 / 2"' do
    g = build_game
    info = g.extract_timeout_information('19:01 / 2', 'home')
    assert_equal '19:01', info[:time]
    assert_equal 2, info[:period]
  end

  test 'extract_timeout_information: kein Match gibt nil zurück' do
    g = build_game
    assert_nil g.extract_timeout_information('ungültiger String', 'home')
    assert_nil g.extract_timeout_information('', 'home')
    assert_nil g.extract_timeout_information('16:22 ohne Periode', 'home')
  end

  # ---------------------------------------------------------------------------
  # sort_events!
  # ---------------------------------------------------------------------------

  test 'sort_events!: Events werden nach Period und Zeit sortiert' do
    events = [
      { 'id' => 1, 'period' => 1, 'time' => '15:00', 'row' => 2, 'event_type' => 'goal', 'event_team' => 'home', 'home_goals' => 0, 'guest_goals' => 0 },
      { 'id' => 2, 'period' => 1, 'time' => '5:00', 'row' => 1, 'event_type' => 'goal', 'event_team' => 'home', 'home_goals' => 0, 'guest_goals' => 0 }
    ]
    g = build_game(events: events)
    g.sort_events!
    assert_equal '5:00', g.events[0]['time']
    assert_equal '15:00', g.events[1]['time']
  end

  test 'sort_events!: Tor-Zähler wird neu berechnet' do
    events = [
      { 'id' => 1, 'period' => 1, 'time' => '5:00', 'row' => 1, 'event_type' => 'goal', 'event_team' => 'home', 'home_goals' => 0, 'guest_goals' => 0 },
      { 'id' => 2, 'period' => 1, 'time' => '10:00', 'row' => 2, 'event_type' => 'goal', 'event_team' => 'guest', 'home_goals' => 0, 'guest_goals' => 0 },
      { 'id' => 3, 'period' => 1, 'time' => '15:00', 'row' => 3, 'event_type' => 'goal', 'event_team' => 'home', 'home_goals' => 0, 'guest_goals' => 0 }
    ]
    g = build_game(events: events)
    g.sort_events!
    assert_equal 1, g.events[0]['home_goals']
    assert_equal 0, g.events[0]['guest_goals']
    assert_equal 1, g.events[1]['home_goals']
    assert_equal 1, g.events[1]['guest_goals']
    assert_equal 2, g.events[2]['home_goals']
    assert_equal 1, g.events[2]['guest_goals']
  end

  test 'sort_events!: Legacy-Spiel überschreibt keine Tor-Zähler' do
    events = [
      { 'id' => 1, 'period' => 1, 'time' => '5:00', 'row' => 1, 'event_type' => 'goal', 'event_team' => 'home', 'home_goals' => 99, 'guest_goals' => 88 }
    ]
    g = build_game(legacy: true, events: events)
    g.sort_events!
    assert_equal 99, g.events[0]['home_goals']
    assert_equal 88, g.events[0]['guest_goals']
  end

  # ---------------------------------------------------------------------------
  # error_checker
  # ---------------------------------------------------------------------------

  test 'error_checker: keine Events → keine Fehler' do
    g = build_game(events: [])
    g.stub(:league, mock_league) do
      assert_empty g.error_checker
    end
  end

  test 'error_checker: error_missing_overtime_checkbox wenn Tor in Verlängerung ohne OT-Flag' do
    # Period 3 events in a KF league (period_count_normal_game=2) without overtime=true
    events = [{ 'period' => 3, 'home_goals' => 1, 'guest_goals' => 0 }]
    g = build_game(overtime: false, events: events)
    g.stub(:league, mock_league(period_count_normal_game: 2)) do
      errors = g.error_checker
      assert errors.any? { |e| e[:key] == 'missing_overtime_checkbox' }
    end
  end

  test 'error_checker: kein missing_overtime_checkbox wenn OT-Flag gesetzt' do
    events = [{ 'period' => 3, 'home_goals' => 1, 'guest_goals' => 0 }]
    g = build_game(overtime: true, events: events)
    g.stub(:league, mock_league(period_count_normal_game: 2, period_penalty_shots: 4)) do
      errors = g.error_checker
      assert_not errors.any? { |e| e[:key] == 'missing_overtime_checkbox' }
    end
  end

  test 'error_checker: error_result_not_increasing wenn Tore sinken' do
    # Scores [2, 1]: strictly decreasing but never zero → only result_not_increasing fires
    events = [
      { 'period' => 1, 'home_goals' => 2, 'guest_goals' => 0 },
      { 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0 }
    ]
    g = build_game(events: events)
    g.stub(:league, mock_league) do
      errors = g.error_checker
      assert errors.any? { |e| e[:key] == 'result_not_increasing' }
      assert_not errors.any? { |e| e[:key] == 'result_zero_after_goals' }
    end
  end

  test 'error_checker: error_result_zero_after_goals wenn 0:0 nach Toren' do
    # Scores [1, 0]: zero after non-zero. Also triggers result_not_increasing (inseparable).
    events = [
      { 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0 },
      { 'period' => 1, 'home_goals' => 0, 'guest_goals' => 0 }
    ]
    g = build_game(events: events)
    g.stub(:league, mock_league) do
      errors = g.error_checker
      assert errors.any? { |e| e[:key] == 'result_zero_after_goals' }
    end
  end
end
