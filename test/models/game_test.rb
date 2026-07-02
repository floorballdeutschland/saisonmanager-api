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

  # ---------------------------------------------------------------------------
  # referee1_present?
  # ---------------------------------------------------------------------------

  test 'referee1_present?: false ohne referee1_string' do
    assert_not build_game(referee1_string: nil).referee1_present?
    assert_not build_game(referee1_string: '').referee1_present?
  end

  test 'referee1_present?: false bei leerem Platzhalter "0 , "' do
    assert_not build_game(referee1_string: '0 , ').referee1_present?
    assert_not build_game(referee1_string: '0 ,').referee1_present?
  end

  test 'referee1_present?: true bei echter Lizenz' do
    assert build_game(referee1_string: '12345 Mustermann, Max').referee1_present?
  end

  test 'referee1_present?: true bei Namenseintrag ohne Lizenz' do
    assert build_game(referee1_string: '0 Mustermann, Max').referee1_present?
  end

  # ---------------------------------------------------------------------------
  # Eingefrorene Straf-Labels (R1)
  # ---------------------------------------------------------------------------

  test 'penalty_mapping: bevorzugt eingefrorenes Label am Event (kein Setting-Lookup)' do
    g = build_game
    assert_equal :penalty_2, g.penalty_mapping('penalty_id' => 1, 'penalty_mapping' => 'penalty_2')
  end

  test 'penalty_mapping_string: bevorzugt eingefrorenen Namen' do
    g = build_game
    assert_equal '2 Minuten', g.penalty_mapping_string('penalty_id' => 1, 'penalty_name' => '2 Minuten')
  end

  test 'penalty_reason: baut Reason aus eingefrorenen Werten' do
    g = build_game
    event = { 'penalty_code_id' => 902, 'penalty_code' => '902', 'penalty_code_description' => 'Stockschlag' }
    assert_equal({ 'code' => '902', 'description' => 'Stockschlag' }, g.penalty_reason(event))
  end

  test 'freeze_penalty_labels: entfernt Labels bei Nicht-Straf-Event' do
    event = { 'penalty_mapping' => 'penalty_2', 'penalty_name' => '2 Minuten', 'goal_type' => 'regular' }
    Game.freeze_penalty_labels(event)
    assert_not event.key?('penalty_mapping')
    assert_not event.key?('penalty_name')
    assert_equal 'regular', event['goal_type']
  end

  test 'freeze_penalty_labels: schreibt Labels aus Setting ins Event' do
    event = { 'penalty_id' => 1, 'penalty_code_id' => 902 }
    setting = OpenStruct.new(
      penalties: { '1' => { 'mapping' => 'penalty_2', 'name' => '2 Minuten' } },
      penalty_codes: { '902' => { 'code' => '902', 'description' => 'Stockschlag' } }
    )
    Setting.stub(:current, setting) do
      Game.freeze_penalty_labels(event)
    end
    assert_equal 'penalty_2', event['penalty_mapping']
    assert_equal '2 Minuten', event['penalty_name']
    assert_equal '902', event['penalty_code']
    assert_equal 'Stockschlag', event['penalty_code_description']
  end

  test 'penalty_reason: Alt-Code (nur name) wird live als Beschreibung aufgelöst' do
    g = build_game
    setting = OpenStruct.new(penalty_codes: { '1' => { 'name' => 'Behinderung' } })
    reason = Setting.stub(:current, setting) { g.penalty_reason('penalty_code_id' => 1) }
    assert_equal({ 'code' => nil, 'description' => 'Behinderung' }, reason)
  end

  test 'freeze_penalty_labels: friert Alt-Code-Bezeichnung (nur name) als Beschreibung ein' do
    event = { 'penalty_id' => 1, 'penalty_code_id' => 1 }
    setting = OpenStruct.new(
      penalties: { '1' => { 'mapping' => 'penalty_2', 'name' => '2 Minuten' } },
      penalty_codes: { '1' => { 'name' => 'Behinderung' } }
    )
    Setting.stub(:current, setting) do
      Game.freeze_penalty_labels(event)
    end
    assert_equal 'Behinderung', event['penalty_code_description']
    assert_not event.key?('penalty_code')
  end

  # ---------------------------------------------------------------------------
  # Scorer-Namen aus dem Snapshot (R2)
  # ---------------------------------------------------------------------------

  test 'empty_score: enthält Namen aus dem Snapshot' do
    g = build_game
    team = OpenStruct.new(id: 5, name: 'Team A')
    score = g.empty_score(42, team, { first_name: 'Max', last_name: 'Muster' })
    assert_equal 'Max', score[:first_name]
    assert_equal 'Muster', score[:last_name]
    assert_equal 42, score[:player_id]
  end

  test 'lineup_player_names: mappt player_id auf Snapshot-Namen' do
    players = {
      'home' => [{ 'trikot_number' => 7, 'player_id' => 42, 'player_firstname' => 'Max', 'player_name' => 'Muster' }],
      'guest' => [{ 'trikot_number' => 9, 'player_id' => 99, 'player_firstname' => 'Erika', 'player_name' => 'Beispiel' }]
    }
    names = build_game(players: players).lineup_player_names
    assert_equal({ first_name: 'Max', last_name: 'Muster' }, names[42])
    assert_equal({ first_name: 'Erika', last_name: 'Beispiel' }, names[99])
  end

  # Regression: die Spielerstatistik (PlayersController#stats) und die
  # Team-Scorerliste lesen aus dem Score-Hash gezielt numerische Keys – die
  # neuen Snapshot-Namen dürfen die Werte nicht verändern.
  test 'evaluate_scorer: Statistik-Keys bleiben numerisch korrekt, Namen zusätzlich' do
    players = {
      'home' => [{ 'trikot_number' => 7, 'player_id' => 42, 'player_firstname' => 'Max', 'player_name' => 'Muster' }],
      'guest' => []
    }
    events = [
      { 'home_number' => 7, 'home_goals' => 1, 'guest_goals' => 0 },
      { 'penalty_id' => 1, 'penalty_mapping' => 'penalty_2', 'home_number' => 7, 'home_goals' => 1, 'guest_goals' => 0 }
    ]
    g = build_game(players: players, events: events)
    score = nil
    g.stub(:home_team, OpenStruct.new(id: 1, name: 'Heim')) do
      g.stub(:guest_team, OpenStruct.new(id: 2, name: 'Gast')) do
        score = g.evaluate_scorer[42]
      end
    end
    assert_equal 1, score[:goals]
    assert_equal 0, score[:assists]
    assert_equal 1, score[:penalty_2]
    assert_equal 1, score[:games]
    assert_equal 1, score[:team_id]
    assert_equal 'Heim', score[:team_name]
    assert_equal 'Max', score[:first_name]
    assert_equal 'Muster', score[:last_name]
  end

  # ---------------------------------------------------------------------------
  # officiating_referees – tatsächlich im Spielbericht eingesetzte Schiris
  # ---------------------------------------------------------------------------

  test 'officiating_referee_licenses: liest Lizenzen aus den Bericht-Strings' do
    g = build_game(referee1_string: '1 Partanen, Aleksi', referee2_string: '2 Muster, Max')
    assert_equal [1, 2], g.officiating_referee_licenses
  end

  test 'officiating_referee_licenses: leerer Slot fällt auf referee_ids zurück' do
    g = build_game(referee1_string: '0 , ', referee2_string: nil, referee_ids: [7])
    assert_equal [7, nil], g.officiating_referee_licenses
  end

  test 'officiating_referee_licenses: ohne jede Angabe leer' do
    g = build_game(referee1_string: nil, referee2_string: nil, referee_ids: [])
    assert_equal [nil, nil], g.officiating_referee_licenses
  end

  test 'officiating_referee_licenses: positionstreu bei leerem Slot 1 in referee_ids' do
    g = build_game(referee1_string: nil, referee2_string: nil, referee_ids: [0, 7])
    assert_equal [nil, 7], g.officiating_referee_licenses
  end

  test 'officiating_referee_names: extrahiert Klartextnamen aus den Strings' do
    g = build_game(referee1_string: '1 Partanen, Aleksi', referee2_string: '2 Muster, Max')
    assert_equal ['Aleksi Partanen', 'Max Muster'], g.officiating_referee_names
  end

  test 'officiating_referees: löst Schiris über die Lizenznummer auf' do
    ref = create(:referee, lizenznummer: 4242, vorname: 'Aleksi', nachname: 'Partanen')
    g = build_game(referee1_string: "#{ref.lizenznummer} Partanen, Aleksi")
    assert_equal [ref.id], g.officiating_referees.map(&:id)
  end

  test 'officiating_referees: leer, wenn keine Lizenz einem Referee entspricht' do
    g = build_game(referee1_string: '999999 Unbekannt, Gast')
    assert_empty g.officiating_referees
  end

  test 'officiating_referees: bevorzugt die kanonische PK-Spalte' do
    ref = create(:referee, lizenznummer: 5555, vorname: 'Pia', nachname: 'Pfiff')
    # Der Bericht-String verweist auf eine andere Lizenz – die PK-Spalte gewinnt.
    g = build_game(officiating_referee_ids: [ref.id, 0], referee1_string: '9999 Anders, Wer')
    assert_equal [ref.id], g.officiating_referees.map(&:id)
  end

  test 'officiating_referees: fällt auf die Lizenz zurück, wenn PK-Spalte leer' do
    ref = create(:referee, lizenznummer: 6161, vorname: 'Rudi', nachname: 'Recht')
    g = build_game(officiating_referee_ids: [], referee1_string: "#{ref.lizenznummer} Recht, Rudi")
    assert_equal [ref.id], g.officiating_referees.map(&:id)
  end
end
