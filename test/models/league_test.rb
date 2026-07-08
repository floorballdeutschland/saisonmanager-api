require 'test_helper'

class LeagueTest < ActiveSupport::TestCase
  # ---------------------------------------------------------------------------
  # age_eligible? (Stichtag-Spielberechtigung)
  # ---------------------------------------------------------------------------

  test 'age_eligible?: before_deadline=true erlaubt geboren bis einschließlich Stichtag' do
    l = League.new(deadline: Date.new(2010, 1, 1), before_deadline: true)
    assert l.age_eligible?(Date.new(2010, 1, 1)), 'Stichtag selbst ist spielberechtigt'
    assert l.age_eligible?(Date.new(2009, 12, 31))
    assert_not l.age_eligible?(Date.new(2010, 1, 2))
  end

  test 'age_eligible?: before_deadline=false erlaubt geboren ab einschließlich Stichtag' do
    l = League.new(deadline: Date.new(2010, 1, 1), before_deadline: false)
    assert l.age_eligible?(Date.new(2010, 1, 1))
    assert l.age_eligible?(Date.new(2011, 6, 15))
    assert_not l.age_eligible?(Date.new(2009, 12, 31))
  end

  test 'age_eligible?: akzeptiert weiterhin String-Geburtsdaten' do
    l = League.new(deadline: Date.new(2010, 1, 1), before_deadline: false)
    assert l.age_eligible?('2010-06-01')
    assert_not l.age_eligible?('2009-06-01')
  end

  test 'age_eligible?: ohne Stichtag oder ohne (lesbares) Geburtsdatum keine Sperre' do
    assert League.new(deadline: nil).age_eligible?(Date.new(1990, 1, 1))

    l = League.new(deadline: Date.new(2010, 1, 1), before_deadline: true)
    assert l.age_eligible?(nil)
    assert l.age_eligible?('unbekannt')
  end

  # ---------------------------------------------------------------------------
  # Pure point calculation methods (no DB needed)
  # ---------------------------------------------------------------------------

  test 'won_points: classic Modus ergibt 3' do
    l = League.new(table_modus: 'classic')
    assert_equal 3, l.won_points
  end

  test 'won_points: non-classic Modus ergibt 10' do
    l = League.new(table_modus: 'points10')
    assert_equal 10, l.won_points
  end

  test 'draw_points: immer 1' do
    assert_equal 1, League.new(table_modus: 'classic').draw_points
    assert_equal 1, League.new(table_modus: 'points10').draw_points
  end

  test 'won_overtime_points: classic ergibt 2' do
    l = League.new(table_modus: 'classic')
    assert_equal 2, l.won_overtime_points
  end

  test 'won_overtime_points: non-classic ergibt 0' do
    l = League.new(table_modus: 'points10')
    assert_equal 0, l.won_overtime_points
  end

  test 'lost_overtime_points: gleich draw_points' do
    l = League.new(table_modus: 'classic')
    assert_equal l.draw_points, l.lost_overtime_points
  end

  # Legacy-League-Zweig (league_system_id == 1 → 3-Punkte-System)
  test 'won_points: legacy System 1 ergibt 3' do
    l = League.new(legacy_league: true, league_system_id: '1')
    assert_equal 3, l.won_points
  end

  test 'won_points: legacy anderes System ergibt 2' do
    l = League.new(legacy_league: true, league_system_id: '2')
    assert_equal 2, l.won_points
  end

  test 'draw_points: legacy System 1 ergibt 1' do
    l = League.new(legacy_league: true, league_system_id: '1')
    assert_equal 1, l.draw_points
  end

  test 'draw_points: legacy anderes System ergibt 0' do
    l = League.new(legacy_league: true, league_system_id: '2')
    assert_equal 0, l.draw_points
  end

  test 'won_overtime_points: legacy System 1 ergibt 2' do
    l = League.new(legacy_league: true, league_system_id: '1')
    assert_equal 2, l.won_overtime_points
  end

  test 'won_overtime_points: legacy anderes System ergibt 0' do
    l = League.new(legacy_league: true, league_system_id: '2')
    assert_equal 0, l.won_overtime_points
  end

  # ---------------------------------------------------------------------------
  # class_rank — Ligastufen-Rang für Erst-/Zweitlizenz-Bestimmung (#291, #297)
  # ---------------------------------------------------------------------------

  test 'class_rank: Codes sortieren nach Ligastufe (kleiner = höher)' do
    assert League.class_rank('1fbl') < League.class_rank('2fbl')
    assert League.class_rank('2fbl') < League.class_rank('rl')
    assert League.class_rank('rl') < League.class_rank('vl')
    assert League.class_rank('vl') < League.class_rank('ll')
  end

  test 'class_rank: unbekannte oder leere Klasse landet am Ende' do
    assert_equal League::UNKNOWN_CLASS_RANK, League.class_rank('foo')
    assert_equal League::UNKNOWN_CLASS_RANK, League.class_rank(nil)
    assert_equal League::UNKNOWN_CLASS_RANK, League.class_rank('')
    assert League.class_rank('ll') < League.class_rank('foo'), 'Landesliga über unbekannt'
  end

  test 'class_rank: liefert JSON-sicheren Integer (kein Float::INFINITY)' do
    assert_kind_of Integer, League.class_rank('1fbl')
    assert_kind_of Integer, League.class_rank('rl')
    assert_kind_of Integer, League.class_rank('foo')
  end

  # ---------------------------------------------------------------------------
  # league_class_id-Validierung (#297)
  # ---------------------------------------------------------------------------

  test 'league_class_id: Codes und leer sind gültig, Legacy-Werte nicht mehr' do
    league = build(:league)

    %w[1fbl 2fbl rl vl ll].each do |code|
      league.league_class_id = code
      assert league.valid?, "#{code} sollte gültig sein"
    end

    [nil, ''].each do |blank|
      league.league_class_id = blank
      assert league.valid?, 'leer sollte gültig sein'
    end

    %w[1 30 520 xx].each do |legacy|
      league.league_class_id = legacy
      assert_not league.valid?, "#{legacy} sollte ungültig sein"
    end
  end

  # ---------------------------------------------------------------------------
  # evaluate_table_results (full object graph needed)
  # ---------------------------------------------------------------------------

  def build_go
    GameOperation.create!(name: 'Test GO', short_name: 'TGO')
  end

  def build_league(go)
    League.create!(
      game_operation: go,
      name: 'Testliga',
      season_id: '1',
      table_modus: 'classic'
    )
  end

  def build_club
    Club.create!
  end

  def build_arena
    Arena.create!(name: 'Testhalle', city: 'Teststadt')
  end

  def build_game_day(league, arena, club)
    GameDay.create!(league: league, arena: arena, club: club, number: 1, date: '2025-01-01')
  end

  def build_team(league, club, name)
    Team.create!(league: league, club: club, name: name)
  end

  def build_game(game_day, home_team, guest_team, attrs = {})
    Game.create!({
      game_day: game_day,
      home_team: home_team,
      guest_team: guest_team,
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: []
    }.merge(attrs))
  end

  test 'evaluate_table_results: Heimsieg ergibt 3 Punkte (classic)' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    home = build_team(league, club, 'Heim')
    guest = build_team(league, club, 'Gast')

    events = [
      { 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 }
    ]
    build_game(game_day, home, guest, events: events)

    results = league.evaluate_table_results(league.games)
    assert_equal 3, results[home.id][:points]
    assert_equal 0, results[guest.id][:points]
    assert_equal 1, results[home.id][:won]
    assert_equal 1, results[guest.id][:lost]
  end

  test 'evaluate_table_results: Unentschieden ergibt je 1 Punkt' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    home = build_team(league, club, 'Heim')
    guest = build_team(league, club, 'Gast')

    events = [
      { 'period' => 1, 'home_goals' => 1, 'guest_goals' => 1, 'row' => 1 }
    ]
    build_game(game_day, home, guest, events: events)

    results = league.evaluate_table_results(league.games)
    assert_equal 1, results[home.id][:points]
    assert_equal 1, results[guest.id][:points]
    assert_equal 1, results[home.id][:draw]
    assert_equal 1, results[guest.id][:draw]
  end

  test 'evaluate_table_results: OT-Sieg ergibt 2 Punkte für Sieger, 1 für Verlierer (classic)' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    home = build_team(league, club, 'Heim')
    guest = build_team(league, club, 'Gast')

    events = [
      { 'period' => 3, 'home_goals' => 2, 'guest_goals' => 1, 'row' => 1 }
    ]
    build_game(game_day, home, guest, events: events, overtime: true)

    results = league.evaluate_table_results(league.games)
    assert_equal 2, results[home.id][:points]
    assert_equal 1, results[guest.id][:points]
    assert_equal 1, results[home.id][:won_ot]
    assert_equal 1, results[guest.id][:lost_ot]
  end

  test 'evaluate_table_results: Gaststieg ergibt korrekte Punkte' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    home = build_team(league, club, 'Heim')
    guest = build_team(league, club, 'Gast')

    events = [
      { 'period' => 1, 'home_goals' => 0, 'guest_goals' => 2, 'row' => 1 }
    ]
    build_game(game_day, home, guest, events: events)

    results = league.evaluate_table_results(league.games)
    assert_equal 0, results[home.id][:points]
    assert_equal 3, results[guest.id][:points]
  end

  test 'table: Teams werden nach Punkten sortiert' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    team_a = build_team(league, club, 'Team A')
    team_b = build_team(league, club, 'Team B')

    # Team A gewinnt 3:0
    events = [{ 'period' => 1, 'home_goals' => 3, 'guest_goals' => 0, 'row' => 1 }]
    build_game(game_day, team_a, team_b, events: events)

    sorted = league.table
    assert_equal 1, sorted.find { |r| r[:team_id] == team_a.id }[:position]
    assert_equal 2, sorted.find { |r| r[:team_id] == team_b.id }[:position]
  end

  test 'table: Punktgleiche Teams erhalten gleiche Position' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    team_a = build_team(league, club, 'Team A')
    team_b = build_team(league, club, 'Team B')
    team_c = build_team(league, club, 'Team C')

    # Team A schlägt Team C, Team B schlägt Team C → A und B je 3 Punkte, C 0
    events_1 = [{ 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 }]
    build_game(game_day, team_a, team_c, events: events_1)
    build_game(game_day, team_b, team_c, events: events_1)

    sorted = league.table
    a_pos = sorted.find { |r| r[:team_id] == team_a.id }[:position]
    b_pos = sorted.find { |r| r[:team_id] == team_b.id }[:position]
    assert_equal a_pos, b_pos
  end

  test 'table: Teams ohne Spiele erscheinen in der Gesamttabelle' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    team_a = build_team(league, club, 'Team A')
    team_b = build_team(league, club, 'Team B')
    team_c = build_team(league, club, 'Ohne Spiele')

    events = [{ 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 }]
    build_game(game_day, team_a, team_b, events: events)

    sorted = league.table
    assert_equal [team_a, team_b, team_c].map(&:id).sort, sorted.map { |r| r[:team_id] }.sort
    assert_equal 0, sorted.find { |r| r[:team_id] == team_c.id }[:games]
  end

  test 'grouped_table: Gruppentabellen enthalten nur die Teams der jeweiligen Gruppe' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    team_a1 = build_team(league, club, 'A1')
    team_a2 = build_team(league, club, 'A2')
    team_b1 = build_team(league, club, 'B1')
    team_b2 = build_team(league, club, 'B2')

    events = [{ 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 }]
    build_game(game_day, team_a1, team_a2, events: events, group_identifier: 'group_a')
    build_game(game_day, team_b1, team_b2, events: events, group_identifier: 'group_b')

    grouped = league.grouped_table
    assert_equal [team_a1.id, team_a2.id].sort, grouped['group_a'][:table].map { |r| r[:team_id] }.sort
    assert_equal [team_b1.id, team_b2.id].sort, grouped['group_b'][:table].map { |r| r[:team_id] }.sort
  end

  test 'grouped_table: geplante (nicht beendete) Gruppenspiele bringen ihre Teams in die Gruppentabelle' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    team_a1 = build_team(league, club, 'A1')
    team_a2 = build_team(league, club, 'A2')

    build_game(game_day, team_a1, team_a2, started: false, ended: false, group_identifier: 'group_a')

    grouped = league.grouped_table
    table = grouped['group_a'][:table]
    assert_equal [team_a1.id, team_a2.id].sort, table.map { |r| r[:team_id] }.sort
    assert table.all? { |r| (r[:games]).zero? }
  end

  test 'grouped_table: Punktekorrekturen wirken auch in der Gruppentabelle' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    team_a1 = build_team(league, club, 'A1')
    team_a2 = build_team(league, club, 'A2')
    league.update!(point_corrections: { team_a1.id.to_s => { 'points' => -2 } })

    # A1 gewinnt (3 Punkte), Korrektur -2 → 1 Punkt
    events = [{ 'period' => 1, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 }]
    build_game(game_day, team_a1, team_a2, events: events, group_identifier: 'group_a')

    table = league.grouped_table['group_a'][:table]
    assert_equal 1, table.find { |r| r[:team_id] == team_a1.id }[:points]
    assert_equal 0, table.find { |r| r[:team_id] == team_a2.id }[:points]
  end

  # ---------------------------------------------------------------------------
  # express_license_window_open?
  # ---------------------------------------------------------------------------

  test 'express_license_window_open?: false ohne Spieltage' do
    go = build_go
    league = build_league(go)
    refute league.express_license_window_open?
  end

  test 'express_license_window_open?: false wenn erster Spieltag > 3 Tage in der Zukunft' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    GameDay.create!(league: league, arena: arena, club: club, number: 1,
                    date: (Date.current + 10).to_s)
    refute league.express_license_window_open?
  end

  test 'express_license_window_open?: true wenn erster Spieltag genau 3 Tage entfernt' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    GameDay.create!(league: league, arena: arena, club: club, number: 1,
                    date: (Date.current + 3).to_s)
    assert league.express_license_window_open?
  end

  test 'express_license_window_open?: true wenn erster Spieltag in der Vergangenheit' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    GameDay.create!(league: league, arena: arena, club: club, number: 1,
                    date: (Date.current - 14).to_s)
    assert league.express_license_window_open?
  end

  test 'express_license_window_open?: nutzt frühesten Spieltag' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    GameDay.create!(league: league, arena: arena, club: club, number: 2,
                    date: (Date.current + 20).to_s)
    GameDay.create!(league: league, arena: arena, club: club, number: 1,
                    date: (Date.current + 1).to_s)
    assert league.express_license_window_open?
  end

  # ---------------------------------------------------------------------------
  # League#licenses — Filter über Saison/Status. Tests via Factories, decken
  # die Pfade aus dem „Bonner-Vorfall" ab.
  # ---------------------------------------------------------------------------

  test 'licenses: Spieler mit APPROVED-Lizenz der Liga-Saison ist enthalten' do
    create(:setting, current_season_id: '18')
    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::APPROVED, season_id: '18' }
    ])

    result = league.licenses
    player_ids = result.flat_map { |t| t[:players].map { |p| p[:id] } }
    assert_includes player_ids, player.id
  end

  test 'licenses: Lizenz mit season_id einer Vorsaison wird ausgefiltert' do
    create(:setting, current_season_id: '18')
    current_league = create(:league, :current_season)
    current_team   = create(:team, league: current_league)

    player = create(:player, with_licenses: [
      { team: current_team, status: License::APPROVED, season_id: '17' }
    ])

    result = current_league.licenses
    player_ids = result.flat_map { |t| t[:players].map { |p| p[:id] } }
    refute_includes player_ids, player.id
  end

  test 'licenses: Lizenz mit season_id == nil rutscht aktuell durch (nil-Bypass in league.rb:715)' do
    # Dokumentiert das aktuelle Verhalten explizit. Wenn jemand das Tightening
    # angeht (z. B. künftig `lic_season.nil?` entfernen), bricht dieser Test
    # bewusst — als Erinnerung, dass das eine Verhaltensänderung ist.
    create(:setting, current_season_id: '18')
    current_league = create(:league, :current_season)
    current_team   = create(:team, league: current_league)

    player = create(:player, with_licenses: [
      { team: current_team, status: License::APPROVED, season_id: nil }
    ])

    result = current_league.licenses
    player_ids = result.flat_map { |t| t[:players].map { |p| p[:id] } }
    assert_includes player_ids, player.id,
                    'nil-Bypass aktiv: season_id=nil durchgelassen — bewusst getestet'
  end

  test 'licenses: DELETED-Lizenz wird ausgefiltert' do
    create(:setting, current_season_id: '18')
    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::DELETED, season_id: '18' }
    ])

    result = league.licenses
    player_ids = result.flat_map { |t| t[:players].map { |p| p[:id] } }
    refute_includes player_ids, player.id
  end

  test 'licenses: DENIED-Lizenz wird ausgefiltert (nicht in active_statuses)' do
    create(:setting, current_season_id: '18')
    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::DENIED, season_id: '18' }
    ])

    result = league.licenses
    player_ids = result.flat_map { |t| t[:players].map { |p| p[:id] } }
    refute_includes player_ids, player.id
  end

  test 'licenses: REQUESTED zählt als aktiv (player taucht auf)' do
    create(:setting, current_season_id: '18')
    league = create(:league, :current_season)
    team   = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team, status: License::REQUESTED, season_id: '18' }
    ])

    result = league.licenses
    player_ids = result.flat_map { |t| t[:players].map { |p| p[:id] } }
    assert_includes player_ids, player.id
  end

  test 'licenses: other_licenses listet Lizenzen anderer Teams derselben Saison' do
    create(:setting, current_season_id: '18')
    target_league = create(:league, :current_season)
    other_league  = create(:league, :current_season)
    target_team   = create(:team, league: target_league)
    other_team    = create(:team, league: other_league)

    player = create(:player, with_licenses: [
      { team: target_team, status: License::APPROVED, season_id: '18' },
      { team: other_team,  status: License::APPROVED, season_id: '18' }
    ])

    result = target_league.licenses
    target_team_block = result.find { |t| t[:id] == target_team.id }
    player_entry = target_team_block[:players].find { |p| p[:id] == player.id }

    refute_nil player_entry
    assert_kind_of Array, player_entry[:other_licenses]
    assert_equal 1, player_entry[:other_licenses].size,
                 'Andere Liga in derselben Saison: in other_licenses sichtbar'
  end

  test 'licenses: other_licenses listet keine Lizenzen aus Vorsaisons' do
    create(:setting, current_season_id: '18')
    target_league   = create(:league, :current_season)
    previous_league = create(:league, :previous_season)
    target_team     = create(:team, league: target_league)
    previous_team   = create(:team, league: previous_league)

    player = create(:player, with_licenses: [
      { team: target_team,   status: License::APPROVED, season_id: '18' },
      { team: previous_team, status: License::APPROVED, season_id: '17' }
    ])

    result = target_league.licenses
    target_team_block = result.find { |t| t[:id] == target_team.id }
    player_entry = target_team_block[:players].find { |p| p[:id] == player.id }

    refute_nil player_entry
    assert_empty player_entry[:other_licenses],
                 'Vorsaison-Lizenz nicht in other_licenses'
  end

  test 'licenses: other_licenses liefert GF-Kontext für die Erst-/Zweitlizenz-Zuordnung' do
    create(:setting, current_season_id: '18')
    target_league = create(:league, :current_season, field_size: 'GF')
    other_league  = create(:league, :current_season, field_size: 'GF', female: false)
    target_team   = create(:team, league: target_league)
    other_team    = create(:team, league: other_league)

    player = create(:player, with_licenses: [
      { team: target_team, status: License::APPROVED, season_id: '18' },
      { team: other_team,  status: License::APPROVED, season_id: '18', gf_role: 'erstlizenz' }
    ])

    result = target_league.licenses
    target_team_block = result.find { |t| t[:id] == target_team.id }
    player_entry = target_team_block[:players].find { |p| p[:id] == player.id }
    entry = player_entry[:other_licenses].first

    refute_nil entry
    # Diese Felder steuern, ob die Genehmigungskarte die Erst-/Zweitlizenz-
    # Auswahl anzeigt – ohne sie verschwindet das Feature stillschweigend.
    assert_equal true, entry[:gf_adult]
    assert_equal false, entry[:female]
    assert_equal 'erstlizenz', entry[:gf_role]
    assert_equal player.licenses.find { |l| l['team_id'] == other_team.id }['id'], entry[:license_id]
    assert_equal License::APPROVED, entry[:last_status_id]
  end

  test 'licenses: other_licenses löst auch Teams derselben Liga auf' do
    create(:setting, current_season_id: '18')
    league = create(:league, :current_season)
    team_a = create(:team, league: league)
    team_b = create(:team, league: league)

    player = create(:player, with_licenses: [
      { team: team_a, status: License::APPROVED, season_id: '18' },
      { team: team_b, status: License::APPROVED, season_id: '18' }
    ])

    result = league.licenses
    team_a_block = result.find { |t| t[:id] == team_a.id }
    player_entry = team_a_block[:players].find { |p| p[:id] == player.id }

    assert_equal 1, player_entry[:other_licenses].size,
                 'Lizenz beim anderen Team derselben Liga muss auflösbar sein'
    assert_equal team_b.name, player_entry[:other_licenses].first[:team_name]
  end

  # ---------------------------------------------------------------------------
  # gf_adult? — Erst-/Zweitlizenz gibt es nur im GF-Erwachsenenbereich
  # ---------------------------------------------------------------------------

  test 'gf_adult?: GF-Erwachsenenligen ja, Jugend und Kleinfeld nein' do
    go = create(:game_operation)
    assert create(:league, game_operation: go, field_size: 'GF').gf_adult?, 'GF ohne age_group = Erwachsene'
    assert create(:league, game_operation: go, field_size: 'GF', age_group: 'Herren').gf_adult?
    assert create(:league, game_operation: go, field_size: 'GF', age_group: 'Ü30').gf_adult?,
           'Ü30 ist Erwachsenenbereich (Regex-Anker \\AU\\d greift nicht auf Ü)'
    refute create(:league, game_operation: go, field_size: 'GF', age_group: 'U17 Junioren').gf_adult?
    refute create(:league, game_operation: go, field_size: 'GF', age_group: 'U19 Juniorinnen').gf_adult?
    refute create(:league, game_operation: go, field_size: 'KF').gf_adult?, 'Kleinfeld nie'
  end

  # ---------------------------------------------------------------------------
  # Scorer aus dem Spielbericht-Snapshot (R2)
  # ---------------------------------------------------------------------------

  test 'scorer: Namen aus dem Snapshot, kein stiller Wegfall ohne Player-Record' do
    go = build_go
    league = build_league(go)
    club = build_club
    arena = build_arena
    game_day = build_game_day(league, arena, club)
    home = build_team(league, club, 'Heim')
    guest = build_team(league, club, 'Gast')

    # player_id 999999 existiert bewusst NICHT als Player-Record
    players = {
      'home' => [{ 'trikot_number' => 7, 'player_id' => 999_999, 'player_firstname' => 'Max', 'player_name' => 'Muster' }],
      'guest' => []
    }
    events = [
      { 'period' => 1, 'time' => '05:00', 'home_number' => 7, 'home_goals' => 1, 'guest_goals' => 0, 'row' => 1 }
    ]
    build_game(game_day, home, guest, players: players, events: events)

    entry = league.scorer.find { |s| s[:player_id] == 999_999 }
    refute_nil entry, 'Scorer mit fehlendem Player-Record darf nicht still wegfallen'
    assert_equal 'Max', entry[:first_name]
    assert_equal 'Muster', entry[:last_name]
    assert_equal 1, entry[:goals]
  end

  # ---------------------------------------------------------------------------
  # Punktekorrekturen & eingefrorene Labels an der Liga (R3)
  # ---------------------------------------------------------------------------

  test 'empty_table_item: Punktekorrektur aus der Liga-Spalte wird angewandt' do
    go = build_go
    league = build_league(go)
    club = build_club
    home = build_team(league, club, 'Heim')
    league.update!(point_corrections: { home.id.to_s => { 'points' => -3 } })

    item = league.empty_table_item(home)
    assert_equal(-3, item[:points])
    assert_equal({ 'points' => -3 }, item[:point_corrections])
  end

  test 'full_hash: liefert eingefrorene Klassen-/Kategorie-Namen' do
    go = build_go
    league = build_league(go)
    league.update!(league_class_name: 'Bundesliga', league_category_name: 'Herren')

    h = league.full_hash
    assert_equal 'Bundesliga', h[:league_class_name]
    assert_equal 'Herren', h[:league_category_name]
  end
end
