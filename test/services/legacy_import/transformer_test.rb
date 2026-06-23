# frozen_string_literal: true

require 'test_helper'

# Verifiziert die reinen Transformationen des Alt-Import-PoC anhand eines echten
# Spiels aus dem MariaDB-Dump (fvd_2012_2013, Begegnung 488, Endstand 3:5).
# Spaltennamen und Werte entsprechen 1:1 dem Alt-Schema.
class LegacyImport::TransformerTest < ActiveSupport::TestCase # rubocop:disable Style/ClassAndModuleChildren
  # Spaltenreihenfolge einer global_*_ereignis-Zeile (ohne id_begegnung).
  EREIGNIS_COLS = %w[
    id_ereignis zeile nr_team1 ass_team1 periode zeit
    tore_team1 tore_team2 id_strafe id_strafcode nr_team2 ass_team2
  ].freeze

  # Baut eine ereignis-Zeile aus den Spaltenwerten. Vor der Konstante definiert,
  # weil EREIGNIS_488 sie zur Ladezeit aufruft.
  def self.e(*cols)
    EREIGNIS_COLS.zip(cols).to_h.merge('id_begegnung' => 488)
  end

  # Begegnung 488 (fvd_2012_2013), Reihenfolge bewusst gemischt → testet die
  # Sortierung nach `zeile`.
  EREIGNIS_488 = [
    e(10_379, 5, 18, 0, 3, '40:34', 1, 4, 0, 0, 0, 0),
    e(10_375, 1, 0, 0, 1, '9:56', 0, 1, 0, 0, 77, 29),
    e(10_382, 8, 12, 18, 3, '55:22', 3, 5, 0, 0, 0, 0),
    e(10_376, 2, 0, 0, 2, '25:21', 0, 2, 0, 0, 24, 77),
    e(10_380, 6, 7, 0, 3, '45:04', 2, 4, 0, 0, 0, 0),
    e(10_377, 3, 0, 0, 2, '29:31', 0, 3, 0, 0, 96, 21),
    e(10_381, 7, 0, 0, 3, '51:06', 2, 5, 0, 0, 9, 41),
    e(10_378, 4, 0, 0, 2, '30:21', 0, 4, 0, 0, 32, 21)
  ].freeze

  # global_*_mitspieler (Spalten: id_mitspieler, id_begegnung, id_spieler,
  # trikotnr, torwart, kapitain, team, name, vorname).
  MITSPIELER_488 = [
    { 'id_spieler' => 476, 'trikotnr' => 1, 'torwart' => 1, 'kapitain' => 0, 'team' => 1, 'name' => 'Jäger', 'vorname' => 'Louis' },
    { 'id_spieler' => 5163, 'trikotnr' => 18, 'torwart' => 0, 'kapitain' => 0, 'team' => 1, 'name' => 'Faber', 'vorname' => 'Christian' },
    { 'id_spieler' => 487, 'trikotnr' => 12, 'torwart' => 0, 'kapitain' => 0, 'team' => 1, 'name' => 'Westermann', 'vorname' => 'Marcel' },
    { 'id_spieler' => 0, 'trikotnr' => 77, 'torwart' => 0, 'kapitain' => 1, 'team' => 2, 'name' => 'Gast', 'vorname' => 'Spieler' }
  ].freeze

  # ── build_events ──────────────────────────────────────────────────────────────
  test 'build_events sortiert nach Zeile und ergibt den korrekten Endstand 3:5' do
    events = LegacyImport::Transformer.build_events(EREIGNIS_488)

    assert_equal 8, events.size
    assert_equal((10_375..10_382).to_a, events.map { |ev| ev['id'] }) # nach zeile sortiert
    assert_equal 3, events.last['home_goals']
    assert_equal 5, events.last['guest_goals']
  end

  test 'build_events erkennt das Tor-Team über den Spielstand-Sprung' do
    events = LegacyImport::Transformer.build_events(EREIGNIS_488)

    first = events.first # 0:1, Gast #77 Assist #29
    assert_equal 'guest', first['event_team']
    assert_equal 'goal', first['event_type']
    assert_equal 77, first['guest_number']
    assert_equal 29, first['guest_assist']
    assert_nil first['home_number']

    home_goal = events.find { |e| e['id'] == 10_379 } # 1:4, Heim #18
    assert_equal 'home', home_goal['event_team']
    assert_equal 18, home_goal['home_number']
    assert_nil home_goal['home_assist'] # ass_team1 war 0
  end

  test 'build_events übernimmt Assists nur wenn vorhanden' do
    events = LegacyImport::Transformer.build_events(EREIGNIS_488)
    last = events.last # 3:5, Heim #12 Assist #18
    assert_equal 12, last['home_number']
    assert_equal 18, last['home_assist']
  end

  test 'build_events mappt Strafen auf penalty_id und penalty_code_id' do
    strafe = self.class.e(20_000, 9, 14, 0, 3, '58:00', 3, 5, 2, 907, 0, 0) # id_strafe=2 (5'), code 907
    events = LegacyImport::Transformer.build_events([strafe])

    pen = events.first
    assert_equal 'penalty', pen['event_type']
    assert_equal 3, pen['penalty_id'] # alt 2 (5') → neu 3
    assert_equal 907, pen['penalty_code_id']
    assert_equal 'home', pen['event_team'] # nr_team1 gesetzt
    assert_equal 14, pen['home_number']
  end

  # ── build_players ───────────────────────────────────────────────────────────────
  test 'build_players gruppiert nach Heim/Gast und übernimmt Trikot/Rolle' do
    players = LegacyImport::Transformer.build_players(MITSPIELER_488)

    assert_equal 3, players['home'].size
    assert_equal 1, players['guest'].size

    goalie = players['home'].find { |p| p['trikot_number'] == 1 }
    assert_equal 476, goalie['player_id']
    assert goalie['goalkeeper']
    assert_equal 'Jäger', goalie['last_name']

    guest = players['guest'].first
    assert_nil guest['player_id'] # id_spieler war 0 → Gastspieler
    assert guest['captain']
    assert_equal 'Gast', guest['last_name']
  end

  test 'build_players bildet alte Spieler-ID via player_id_map auf neue ID ab' do
    players = LegacyImport::Transformer.build_players(MITSPIELER_488, player_id_map: { 476 => 99_001 })
    goalie = players['home'].find { |p| p['trikot_number'] == 1 }
    assert_equal 99_001, goalie['player_id']
  end

  # global_*_betreuer (eine Zeile je Begegnung+Team; betreuer1..5 Freitext,
  # Unterschrift nur für betreuer1).
  BETREUER_488 = [
    { 'id_begegnung' => 488, 'team' => 1, 'betreuer1' => 'Schmidt, Anna', 'betreuer2' => 'Weber, Tom',
      'betreuer3' => nil, 'betreuer4' => nil, 'betreuer5' => nil, 'betreuer1_unterschrift' => 1 },
    { 'id_begegnung' => 488, 'team' => 2, 'betreuer1' => 'Klein, Eva', 'betreuer2' => nil,
      'betreuer3' => nil, 'betreuer4' => nil, 'betreuer5' => nil, 'betreuer1_unterschrift' => 0 }
  ].freeze

  # global_*_spielbericht-Zeile (eine je Begegnung).
  SPIELBERICHT_488 = {
    'id_begegnung' => 488,
    'schiedsrichter1' => 'Müller, Max', 'schiedsrichter2' => 'Lang, Lea',
    'unterschrift_schiri1' => 1, 'unterschrift_schiri2' => 0,
    'unterschrift_kapitain1' => 1, 'unterschrift_kapitain2' => 1,
    'timeout1' => '45:12', 'timeout2' => nil,
    'kommentar' => 'Verspäteter Anpfiff', 'protest' => 0, 'verlaengerung' => 1
  }.freeze

  # ── build_coaches ───────────────────────────────────────────────────────────────
  test 'build_coaches baut den Hash home_team_coaches/guest_team_coaches im Live-Format' do
    coaches = LegacyImport::Transformer.build_coaches(BETREUER_488)

    assert_equal 'Schmidt, Anna', coaches['home']['coach1_string']
    assert_equal 'Weber, Tom', coaches['home']['coach2_string']
    assert coaches['home']['coach1_signed'] # betreuer1_unterschrift = 1
    refute coaches['home'].key?('coach3_string') # leere Betreuer nicht gesetzt

    assert_equal 'Klein, Eva', coaches['guest']['coach1_string']
    refute coaches['guest'].key?('coach1_signed') # Unterschrift = 0
  end

  test 'build_coaches liefert leere Hashes ohne Betreuer' do
    coaches = LegacyImport::Transformer.build_coaches([])
    assert_empty coaches['home']
    assert_empty coaches['guest']
  end

  # ── spielbericht_attrs ────────────────────────────────────────────────────────────
  test 'spielbericht_attrs mappt Schiri-Freitext, Timeouts, Kommentar, Protest, Verlängerung' do
    attrs = LegacyImport::Transformer.spielbericht_attrs(SPIELBERICHT_488)

    assert_equal 'Müller, Max', attrs[:referee1_string]
    assert_equal 'Lang, Lea', attrs[:referee2_string]
    assert attrs[:referee1_signed]
    refute attrs[:referee2_signed]
    assert attrs[:home_captain_signed]
    assert_equal '45:12', attrs[:home_timeout_string]
    refute attrs.key?(:guest_timeout_string) # timeout2 war nil → via compact entfernt
    assert_equal 'Verspäteter Anpfiff', attrs[:record_comment]
    refute attrs[:protest]
    assert attrs[:overtime]
  end

  test 'spielbericht_attrs liefert {} ohne Bericht' do
    assert_empty LegacyImport::Transformer.spielbericht_attrs(nil)
  end

  # ── league_attrs (Vokabular) ────────────────────────────────────────────────────
  test 'league_attrs mappt Klasse, Feldgröße, Saison und setzt legacy_league' do
    liga = {
      'id_liga' => 5, 'id_spielsystem' => 1, 'id_klasse' => 30, 'id_kategorie' => 1,
      'id_saison' => 5, 'name' => 'Regionalliga Nord', 'kurzname' => 'RL Nord',
      'weiblich' => 0, 'ordnungsnr' => 3, 'stichtag' => nil, 'klasse_name' => 'Regionalliga'
    }
    attrs = LegacyImport::Transformer.league_attrs(liga, game_operation_id: 1)

    assert_equal '5', attrs[:season_id] # 2013/14
    assert_equal 'rl', attrs[:league_class_id]
    # Alt-Kategorie 1 (Großfeld) wird 1:1 als league_category_id übernommen –
    # League#forfait_goals/#period_count_normal_game/#league_type branchen darauf.
    assert_equal '1', attrs[:league_category_id]
    assert_nil attrs[:field_size]
    assert_equal 'three_point', attrs[:table_modus]
    assert attrs[:legacy_league]
    refute attrs[:female]
  end

  test 'league_attrs flaggt eine unbekannte Klasse als nicht gemappt' do
    liga = { 'id_klasse' => 9999, 'id_kategorie' => 2, 'id_saison' => 4, 'id_spielsystem' => 2,
             'name' => 'Sonderliga', 'kurzname' => 'SL', 'weiblich' => 0, 'ordnungsnr' => 1 }
    attrs = LegacyImport::Transformer.league_attrs(liga, game_operation_id: 1)
    assert_nil attrs[:league_class_id]
    assert_equal '2', attrs[:league_category_id] # KF, Passthrough
  end
end
