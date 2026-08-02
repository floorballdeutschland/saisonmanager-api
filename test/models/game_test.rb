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
  # Technisches Tor
  # ---------------------------------------------------------------------------

  def technical_goal_event(extra = {})
    {
      'id' => 1, 'period' => 1, 'time' => '12:34', 'event_type' => 'goal', 'event_team' => 'home',
      'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 7, 'goal_type' => 'technical'
    }.merge(extra)
  end

  test 'technical_goal?: erkennt nur die Markierung technical' do
    assert Game.technical_goal?('goal_type' => 'technical')
    assert_not Game.technical_goal?('goal_type' => 'regular')
    assert_not Game.technical_goal?({})
  end

  test 'formatted_events: technisches Tor wird als Tor mit eigenem Label geliefert' do
    g = build_game(events: [technical_goal_event('home_assist' => 9)])
    e = g.formatted_events.first
    assert_equal :goal, e[:event_type]
    assert_equal :technical, e[:goal_type]
    assert_equal 'Technisches Tor', e[:goal_type_string]
    assert_equal 7, e[:number]
    # Auch ein zugesprochenes Tor kann vorbereitet worden sein.
    assert_equal 9, e[:assist]
  end

  # Die neue Vorab-Prüfung darf die bestehenden Torarten nicht verschlucken:
  # ohne Markierung muss dieselbe Kette wie vorher greifen.
  test 'formatted_events: reguläres Tor bleibt unverändert' do
    g = build_game(events: [technical_goal_event.except('goal_type')])
    e = g.formatted_events.first
    assert_equal :regular, e[:goal_type]
    assert_equal 'Tor', e[:goal_type_string]
  end

  test 'formatted_events: Strafschuss bleibt Strafschuss' do
    g = build_game(events: [technical_goal_event.except('goal_type').merge('penalty_code_id' => 23)])
    e = g.formatted_events.first
    assert_equal :penalty_shot, e[:goal_type]
    assert_equal 'Strafschuss', e[:goal_type_string]
  end

  # Eigentor und „nicht angegeben" stehen anstelle eines Schützen (Pseudo-Nummern
  # 1000/2000) und gehen der Markierung vor. Sonst verdrängte das technische Tor
  # das Label, und die Ereignisliste zeigte eine leere Zeile: zu 1000/2000 ist
  # kein Spieler auflösbar, und der Hinweis hängt am aufgelösten Namen.
  test 'formatted_events: Eigentor behält sein Label trotz Markierung' do
    g = build_game(events: [technical_goal_event('home_number' => 1000)])
    assert_equal :owngoal, g.formatted_events.first[:goal_type]
  end

  test 'formatted_events: „nicht angegeben" behält sein Label trotz Markierung' do
    g = build_game(events: [technical_goal_event('home_number' => 2000)])
    assert_equal :not_assigned, g.formatted_events.first[:goal_type]
  end

  # Ein technisches Tor zählt wie jedes andere Tor, Vorlage eingeschlossen. Die
  # Wertung hängt an den Trikotnummern, nicht an der Torart; dieser Test hält
  # fest, dass die neue Markierung daran nichts ändert.
  test 'evaluate_scorer: technisches Tor zählt als Tor, Vorlage eingeschlossen' do
    g = build_game(
      events: [technical_goal_event('home_assist' => 9)],
      players: { 'home' => [{ 'trikot_number' => 7, 'player_id' => 42 },
                            { 'trikot_number' => 9, 'player_id' => 43 }], 'guest' => [] }
    )
    score = nil
    g.stub(:home_team, OpenStruct.new(id: 1, name: 'Heim')) do
      score = g.evaluate_scorer
    end
    assert_equal 1, score[42][:goals]
    assert_equal 1, score[43][:assists]
  end

  # Der Ticker trennt Tore von Strafen über penalty_code_id und sieht die
  # Torart nie an. Das technische Tor kommt hier also nur richtig heraus,
  # solange es ohne Strafcode gespeichert wird – Regressionsschutz für den
  # Fall, dass jemand doch auf einen Pseudo-Code umstellt.
  test 'ticker_events: technisches Tor ist ein Tor, keine Strafe' do
    g = build_game(events: [technical_goal_event])
    assert_equal 'HOME_GOAL', g.ticker_events.first[:eventType]
  end

  # Beide Markierungen an einem Ereignis verhindern die Schreibwege
  # (drop_penalty_shot_marker!, siehe GamesControllerTest). Kommt die
  # Kombination trotzdem aus Altdaten, entscheidet die Reihenfolge der Zweige:
  # die Markierung gewinnt, statt dass die Anzeige zwischen beiden kippt.
  test 'formatted_events: Markierung geht dem Strafschuss vor' do
    g = build_game(events: [technical_goal_event('penalty_code_id' => 23)])
    assert_equal :technical, g.formatted_events.first[:goal_type]
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

  test 'by_referee_id: findet Spiele über officiating_referee_ids (PK) und referee_ids (Lizenz)' do
    go     = GameOperation.create!(name: 'GO byRef', short_name: 'GBR')
    club   = Club.create!
    arena  = Arena.create!(name: 'Halle B', city: 'Stadt B')
    league = League.create!(game_operation: go, season_id: '10', name: 'Liga B', table_modus: 'classic')
    day    = GameDay.create!(league: league, arena: arena, club: club, number: 1, date: '2024-01-01')

    by_pk = Game.create!(game_day: day, officiating_referee_ids: [42, 0],
                         events: [], players: { 'home' => [], 'guest' => [] },
                         forfait: 0, overtime: false, legacy: false)
    by_license = Game.create!(game_day: day, referee_ids: [42],
                              events: [], players: { 'home' => [], 'guest' => [] },
                              forfait: 0, overtime: false, legacy: false)
    unrelated = Game.create!(game_day: day, officiating_referee_ids: [99],
                             events: [], players: { 'home' => [], 'guest' => [] },
                             forfait: 0, overtime: false, legacy: false)

    result = Game.by_referee_id(42)
    assert_includes result, by_pk
    assert_includes result, by_license
    assert_not_includes result, unrelated
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

  # ---------------------------------------------------------------------------
  # can_edit_lineup?: Spielbetriebs-Scoping (#214)
  # ---------------------------------------------------------------------------

  test 'can_edit_lineup?: LV-SBK darf ein Spiel des eigenen Spielbetriebs bearbeiten' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation)
    game = scoped_game(go)

    assert game.can_edit_lineup?(sbk_user(go.id))
  end

  test 'can_edit_lineup?: LV-SBK aus Verband A darf ein Spiel aus Verband B nicht bearbeiten' do
    create(:setting, current_season_id: '18')
    go_a = create(:game_operation)
    go_b = create(:game_operation)
    game = scoped_game(go_b)

    assert_not game.can_edit_lineup?(sbk_user(go_a.id))
  end

  test 'can_edit_lineup?: FD-SBK (nationaler Spielbetrieb) darf verbandsübergreifend bearbeiten' do
    create(:setting, current_season_id: '18')
    fd = create(:game_operation, :national)
    game = scoped_game(create(:game_operation))

    assert game.can_edit_lineup?(sbk_user(fd.id))
  end

  test 'can_edit_lineup?: Admin bleibt global' do
    create(:setting, current_season_id: '18')
    game = scoped_game(create(:game_operation))
    admin = build_user([{ 'user_group_id' => 1, 'game_operation_id' => 0 }])

    assert game.can_edit_lineup?(admin)
  end

  # Regression zu #213: eine nicht passende SBK-Rolle darf den VM-Zweig nicht
  # verdecken, sonst sperrt die schwächere Rolle die stärkere aus.
  test 'can_edit_lineup?: fremde SBK-Rolle verdeckt den VM-Zugriff auf das eigene Spiel nicht' do
    create(:setting, current_season_id: '18')
    go_a = create(:game_operation)
    go_b = create(:game_operation)
    club = create(:club)
    league = create(:league, game_operation: go_b, season_id: '18')
    home = create(:team, league: league, club: club)
    game = create(:game, game_day: create(:game_day, league: league), home_team_id: home.id)

    user = build_user(
      [
        { 'user_group_id' => 2, 'game_operation_id' => go_a.id },
        { 'user_group_id' => 4, 'club_id' => club.id }
      ]
    )

    assert game.can_edit_lineup?(user)
  end

  # Zweite Hälfte der Additivität: der TM-Zweig ist erst seit #214 überhaupt
  # erreichbar, wenn zugleich eine fachfremde SBK-Rolle vorliegt.
  test 'can_edit_lineup?: fremde SBK-Rolle verdeckt den TM-Zugriff auf das eigene Spiel nicht' do
    create(:setting, current_season_id: '18')
    go_a = create(:game_operation)
    league = create(:league, game_operation: create(:game_operation), season_id: '18')
    home = create(:team, league: league)
    game = create(:game, game_day: create(:game_day, league: league), home_team_id: home.id)

    user = build_user([{ 'user_group_id' => 2, 'game_operation_id' => go_a.id },
                       { 'user_group_id' => 5, 'game_operation_id' => 0 }], teams: [home.id])

    assert game.can_edit_lineup?(user)
  end

  # Der VM des ausrichtenden Vereins ist der einzige Unterschied zwischen
  # can_edit_lineup? und der Inline-Logik in games#set_string. Genau diese
  # Personen füllen den Bericht vor Ort aus.
  test 'can_edit_lineup?: VM des ausrichtenden Vereins darf bearbeiten' do
    create(:setting, current_season_id: '18')
    hosting_club = create(:club)
    league = create(:league, game_operation: create(:game_operation), season_id: '18')
    game_day = create(:game_day, league: league, club: hosting_club)
    game = create(:game, game_day: game_day)

    user = build_user([{ 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => hosting_club.id }])

    assert game.can_edit_lineup?(user)
  end

  # Fail closed: ohne auflösbaren Spielbetrieb (Altdaten, Rohimport) greift der
  # SBK-Zweig nicht. Admin bleibt zuständig.
  test 'can_edit_lineup?: ohne Spielbetrieb am Spiel greift der SBK-Zweig nicht' do
    create(:setting, current_season_id: '18')
    go = create(:game_operation)
    league = create(:league, game_operation: go, season_id: '18')
    game = create(:game, game_day: create(:game_day, league: league))
    league.update_columns(game_operation_id: nil)

    assert_not game.reload.can_edit_lineup?(sbk_user(go.id))
    assert game.can_edit_lineup?(build_user([{ 'user_group_id' => 1, 'game_operation_id' => 0 }]))
  end

  # ---------------------------------------------------------------------------
  # formatted_events: Meldung „missing scorer"
  # ---------------------------------------------------------------------------

  # Ein Event ohne Spielernummer und ohne Tor-/Straf-/Standmarkierung liegt in
  # einzelnen Spielen in der Datenbank (u. a. mit einer ID aus dem für Time-Outs
  # belegten Bereich) und erzeugte eine Sentry-Meldung pro Seitenaufruf.
  test 'formatted_events meldet Leerzeilen ohne Tor- und Strafbezug nicht' do
    game = game_with_events([
      { 'id' => Game::TIMEOUT_EVENT_ID_BASE + 2, 'time' => '16:46', 'period' => 1,
        'event_team' => 'guest', 'home_goals' => nil, 'guest_goals' => nil, 'guest_number' => nil }
    ])

    messages = capture_sentry_messages { game.formatted_events }

    assert_empty messages
  end

  # Der eigentliche Regressionstest: sort_events! laeuft bei jedem add/update/
  # remove_event ueber alle Zeilen und schreibt den laufenden Spielstand auch in
  # eine leere Zeile. Wuerde scoring_event? auf home_goals/guest_goals sehen,
  # waere die Zeile ab der ersten Bearbeitung des Spiels wieder ein Treffer
  # (0.present? ist true) und die Meldung kaeme zurueck.
  test 'formatted_events meldet Leerzeilen auch nach sort_events! nicht' do
    game = game_with_events([
      { 'id' => Game::TIMEOUT_EVENT_ID_BASE + 2, 'time' => '16:46', 'period' => 1,
        'event_team' => 'guest', 'home_goals' => nil, 'guest_goals' => nil, 'guest_number' => nil }
    ])
    game.sort_events!

    assert_equal 0, game.events.first['home_goals'], 'Vorbedingung: sort_events! stempelt den Stand'

    messages = capture_sentry_messages { game.formatted_events }

    assert_empty messages
  end

  test 'formatted_events meldet ein Tor ohne Schuetzen weiterhin' do
    game = game_with_events([
      { 'id' => 1, 'time' => '05:00', 'period' => 1, 'event_team' => 'home',
        'event_type' => 'goal', 'home_goals' => 1, 'guest_goals' => 0 }
    ])

    messages = capture_sentry_messages { game.formatted_events }

    assert_equal 1, messages.size
    assert_includes messages.first, 'missing scorer'
  end

  # Ein Tor beim Stand 0:0 ohne gesetzten goal_type: nur event_type weist die
  # Zeile als Tor aus. Ohne event_type in SCORING_EVENT_KEYS fiele genau dieses
  # Tor stillschweigend aus der Ueberwachung.
  test 'formatted_events meldet ein Tor ohne Schuetzen auch beim Stand 0:0' do
    game = game_with_events([
      { 'id' => 1, 'time' => '00:42', 'period' => 1, 'event_team' => 'home',
        'event_type' => 'goal', 'home_goals' => 0, 'guest_goals' => 0 }
    ])

    messages = capture_sentry_messages { game.formatted_events }

    assert_equal 1, messages.size
    assert_includes messages.first, 'missing scorer'
  end

  # Eine Strafe ohne Spielernummer bleibt meldepflichtig, auch wenn der
  # Strafenkatalog-Eintrag fehlt: event_type traegt die Zeile.
  test 'formatted_events meldet eine Strafe ohne Schuetzen weiterhin' do
    game = game_with_events([
      { 'id' => 2, 'time' => '12:00', 'period' => 2, 'event_team' => 'guest',
        'event_type' => 'penalty', 'penalty_id' => 7 }
    ])

    messages = capture_sentry_messages { game.formatted_events }

    assert_equal 1, messages.size
    assert_includes messages.first, 'missing scorer'
  end

  test 'formatted_events haengt die Time-Out-Pseudo-Events an' do
    game = game_with_events([], home_timeout_string: '16:22 / 1')

    timeout = game.formatted_events.find { |e| e[:event_type] == 'timeout' }

    assert_equal Game::TIMEOUT_EVENT_ID_BASE + 1, timeout[:event_id]
  end

  private

  def game_with_events(events, attrs = {})
    create(:setting, current_season_id: '18')
    league = create(:league, game_operation: create(:game_operation), season_id: '18')
    create(:game, { game_day: create(:game_day, league: league), events: events }.merge(attrs))
  end

  def capture_sentry_messages(&block)
    messages = []
    Sentry.stub(:capture_message, ->(message, *) { messages << message }, &block)
    messages
  end

  def scoped_game(game_operation)
    league = create(:league, game_operation: game_operation, season_id: '18')
    create(:game, game_day: create(:game_day, league: league))
  end

  def sbk_user(go_id)
    build_user([{ 'user_group_id' => 2, 'game_operation_id' => go_id }])
  end

  def build_user(permissions, teams: [])
    User.create!(
      user_name: "gt_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: permissions,
      teams: teams
    )
  end
end
