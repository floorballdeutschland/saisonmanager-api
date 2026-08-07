require 'test_helper'
require 'rake'

# Tests für lib/tasks/referees_backfill_beendete.rake: Nachimport der
# Karriere-Beendeten und Nachziehen fehlender Vereinszuordnungen. Beide Tasks
# schreiben nur mit DRY_RUN=false.
class RefereesBackfillBeendeteTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    Rails.cache.clear
    create(:setting, current_season_id: '19')
    Setting.current.update!(seasons: { '19' => { 'name' => '2026/2027' } })
    Rails.cache.clear
    @csv = Tempfile.new(['stammdaten', '.csv'])
    # Die ausgelieferte Alias-Datei traegt Produktions-Vereins-IDs, die es in
    # der Test-Datenbank nicht gibt — der Alias-Check wuerde zu Recht abbrechen.
    # Die Tests fahren deshalb mit einer leeren Alias-Liste.
    @aliases = Tempfile.new(['aliases', '.yml'])
    @aliases.write("--- {}\n")
    @aliases.flush
  end

  teardown do
    @csv.close!
    @aliases.close!
  end

  HEADER = 'lizenznummer;nachname;vorname;geburtsdatum;verein;verband;aktiv;lizenz;lizenz_jahr'.freeze

  def write_csv(*zeilen)
    @csv.write([HEADER, *zeilen].join("\n"))
    @csv.flush
    @csv.path
  end

  def run_task(name, env = {})
    task = Rake::Task[name]
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def backfill(env = {})
    run_task('referees2025:backfill_beendete', { 'CSV' => @csv.path, 'ALIASES' => @aliases.path }.merge(env))
  end

  def write_aliases(mapping)
    eintraege = mapping.map { |name, id| "'#{name}': #{id}\n" }.join
    File.write(@aliases.path, "---\n#{eintraege}")
  end

  def fill_club_ids(env = {})
    run_task('referees2025:fill_club_ids', { 'CSV' => @csv.path, 'ALIASES' => @aliases.path }.merge(env))
  end

  test 'legt Beendete an und leitet Gültigkeit aus dem Kursjahr ab' do
    create(:club, name: 'TSV Beispiel')
    write_csv('900001;Beendetsen;Clara;01.02.1980;TSV Beispiel;NRW;0;L2;2021')

    assert_difference -> { Referee.count }, 1 do
      backfill('DRY_RUN' => 'false')
    end

    referee = Referee.find_by(lizenznummer: 900_001)

    assert_equal 'Beendetsen', referee.nachname
    assert_equal Date.new(1980, 2, 1), referee.geburtsdatum
    assert_equal 'L2', referee.lizenzstufe
    # Kursjahr 2021 → Regeljahr 2022 → 31.07.2022, damit Karriere beendet.
    assert_equal Date.new(2022, 7, 31), referee.gueltigkeit
    assert_predicate referee, :career_ended?
    assert_equal Club.find_by(name: 'TSV Beispiel').id, referee.club_id
  end

  test 'Kursjahr ohne Regeljahr ergibt den 30.09.' do
    write_csv('900002;Aoo;Bea;;;NRW;0;L1;2016')
    backfill('DRY_RUN' => 'false')

    assert_equal Date.new(2017, 9, 30), Referee.find_by(lizenznummer: 900_002).gueltigkeit
  end

  test 'DRY_RUN ist Standard und schreibt nichts' do
    write_csv('900003;Coo;Dora;;;NRW;0;L2;2015')

    assert_no_difference -> { Referee.count } do
      backfill
    end
  end

  test 'aktive Zeilen bleiben unangetastet' do
    write_csv('900004;Eoo;Fritz;;;NRW;1;L2;2025')

    assert_no_difference -> { Referee.count } do
      backfill('DRY_RUN' => 'false')
    end
  end

  test 'Statustext im Vereinsfeld ergibt keinen Verein' do
    write_csv('900005;Goo;Hans;;Karriere beendet;NRW;0;L2;2015')
    backfill('DRY_RUN' => 'false')

    assert_nil Referee.find_by(lizenznummer: 900_005).club_id
  end

  test 'vorhandene Nummer mit gleichem Namen: nur leere Felder werden ergänzt' do
    referee = create(:referee, lizenznummer: 900_006, nachname: 'Ioo', vorname: 'Karl',
                               lizenzstufe: 'N2', gueltigkeit: nil, geburtsdatum: nil)
    write_csv('900006;Ioo;Karl;03.04.1975;;NRW;0;L2;2015')

    assert_no_difference -> { Referee.count } do
      backfill('DRY_RUN' => 'false')
    end

    referee.reload

    assert_equal Date.new(1975, 4, 3), referee.geburtsdatum, 'leeres Feld wird ergänzt'
    assert_equal 'N2', referee.lizenzstufe, 'gesetztes Feld bleibt unangetastet'
    assert_equal Date.new(2016, 9, 30), referee.gueltigkeit
  end

  test 'vorhandene Nummer mit anderem Namen wird gemeldet, nicht überschrieben' do
    referee = create(:referee, lizenznummer: 900_007, nachname: 'Fremd', vorname: 'Person')
    write_csv('900007;Andere;Person;;;NRW;0;L2;2015')

    out, = backfill('DRY_RUN' => 'false')

    assert_equal 'Fremd', referee.reload.nachname
    assert_match(/Namenskonflikt, nichts geändert:\s+1/, out)
    assert_match(/Lizenznr\. 900007/, out)
  end

  test 'fill_club_ids füllt nur leere Zuordnungen und meldet Widersprüche' do
    alt = create(:club, name: 'SV Alt')
    neu = create(:club, name: 'SV Neu', long_name: 'SV Neu 1900 e.V.')
    ohne = create(:referee, lizenznummer: 900_010, nachname: 'Ohne', vorname: 'Verein', club_id: nil)
    gesetzt = create(:referee, lizenznummer: 900_011, nachname: 'Mit', vorname: 'Verein', club_id: alt.id)
    write_csv(
      '900010;Ohne;Verein;;SV Neu 1900 e.V.;NRW;1;L2;2024',
      '900011;Mit;Verein;;SV Neu;NRW;1;L2;2024'
    )

    out, = fill_club_ids('DRY_RUN' => 'false')

    assert_equal neu.id, ohne.reload.club_id, 'long_name-Treffer füllt die leere Zuordnung'
    assert_equal alt.id, gesetzt.reload.club_id, 'gesetzte Zuordnung bleibt unangetastet'
    assert_match(/davon Widerspruch zur Excel:\s+1/, out)
  end

  # Eine fehlerhafte Zeile muss den ganzen Lauf zuruecknehmen. Sonst entstuende
  # ein halb importierter Bestand, den niemand von einem vollstaendigen
  # unterscheiden kann.
  test 'eine ungueltige Zeile rollt den gesamten Lauf zurueck und endet mit exit 1' do
    write_csv(
      '900020;Gut;Gunda;;;NRW;0;L2;2015',
      ';Ohne;Nummer;;;NRW;0;L2;2015'
    )

    assert_no_difference -> { Referee.count } do
      assert_raises(SystemExit) { backfill('DRY_RUN' => 'false') }
    end

    assert_not Referee.exists?(lizenznummer: 900_020), 'gueltige Zeile muss mit zurueckgerollt werden'
  end

  test 'fehlende Pflichtspalte bricht ab, statt den Filter ins Leere laufen zu lassen' do
    @csv.write("lizenznummer;nachname;vorname\n900021;Kopf;Karl")
    @csv.flush

    assert_raises(SystemExit) { backfill }
  end

  test 'gemergte Dublette wird nicht als vorhandener Datensatz behandelt' do
    master = create(:referee, lizenznummer: 900_030, nachname: 'Master', vorname: 'Max')
    dublette = create(:referee, lizenznummer: 900_031, nachname: 'Master', vorname: 'Max')
    dublette.update_column(:merged_into_id, master.id)
    write_csv('900031;Master;Max;05.05.1980;;NRW;0;L2;2015')

    out, = backfill('DRY_RUN' => 'false')

    assert_nil dublette.reload.gueltigkeit, 'gemergte Dublette darf nicht befuellt werden'
    assert_nil dublette.lizenzstufe
    assert_match(/gemergt/, out)
    assert_match(/Namenskonflikt, nichts geändert:\s+1/, out)
  end

  test 'fill_club_ids ordnet keinen Verein zu, wenn der Name abweicht' do
    club = create(:club, name: 'SV Fremd')
    fremd = create(:referee, lizenznummer: 900_040, nachname: 'Fremd', vorname: 'Frida', club_id: nil)
    write_csv('900040;Andere;Person;;SV Fremd;NRW;1;L2;2024')

    out, = fill_club_ids('DRY_RUN' => 'false')

    assert_nil fremd.reload.club_id, "Verein #{club.id} darf nicht an eine andere Person gehen"
    assert_match(/Namenskonflikt, nichts geändert:\s+1/, out)
  end

  test 'fill_club_ids zaehlt Zeilen ohne Entsprechung in der DB' do
    write_csv('900050;Unbekannt;Ute;;SV Irgendwo;NRW;1;L2;2024')

    out, = fill_club_ids

    assert_match(/Keine Entsprechung in der DB:\s+1/, out)
  end

  # Die Ausnahme von „nie ueberschreiben": Ein Alias ist von FD benannt, kein
  # geratener Namenstreffer. So sind 36 Schiedsrichter aufgefallen, die an einem
  # Verein 400 km entfernt im falschen Landesverband hingen.
  test 'FIX_ALIAS_CONFLICTS korrigiert eine falsche Zuordnung aus der Alias-Liste' do
    falsch = create(:club, name: 'Floorball Griedel')
    richtig = create(:club, name: 'SV Jeetze Salzwedel')
    write_aliases('Floorball Grizzlys Salzwedel' => richtig.id)
    referee = create(:referee, lizenznummer: 900_060, nachname: 'Griz', vorname: 'Gerd',
                               club_id: falsch.id)
    write_csv('900060;Griz;Gerd;;Floorball Grizzlys Salzwedel;NRW;1;L2;2024')

    out, = fill_club_ids('DRY_RUN' => 'false', 'FIX_ALIAS_CONFLICTS' => 'true')

    assert_equal richtig.id, referee.reload.club_id
    assert_match(/Bestehende Zuordnung korrigiert:\s+1/, out)
  end

  test 'ohne FIX_ALIAS_CONFLICTS bleibt die falsche Zuordnung stehen' do
    falsch = create(:club, name: 'Floorball Griedel')
    richtig = create(:club, name: 'SV Jeetze Salzwedel')
    write_aliases('Floorball Grizzlys Salzwedel' => richtig.id)
    referee = create(:referee, lizenznummer: 900_061, nachname: 'Griz', vorname: 'Gerd',
                               club_id: falsch.id)
    write_csv('900061;Griz;Gerd;;Floorball Grizzlys Salzwedel;NRW;1;L2;2024')

    out, = fill_club_ids('DRY_RUN' => 'false')

    assert_equal falsch.id, referee.reload.club_id
    assert_match(/davon Widerspruch zur Excel:\s+1/, out)
  end

  # Namens- und normalisierte Treffer sind Heuristik. Sie duerfen auch mit
  # gesetztem Schalter niemals eine bestehende Zuordnung ueberschreiben.
  test 'FIX_ALIAS_CONFLICTS korrigiert KEINE Namenstreffer' do
    falsch = create(:club, name: 'SV Alt')
    create(:club, name: 'Hannover Mustangs')
    referee = create(:referee, lizenznummer: 900_062, nachname: 'Mus', vorname: 'Tang',
                               club_id: falsch.id)
    write_csv('900062;Mus;Tang;;Hannover Mustangs;NRW;1;L2;2024')

    out, = fill_club_ids('DRY_RUN' => 'false', 'FIX_ALIAS_CONFLICTS' => 'true')

    assert_equal falsch.id, referee.reload.club_id, 'Namenstreffer darf nicht korrigieren'
    assert_match(/davon Widerspruch zur Excel:\s+1/, out)
  end

  test 'fill_club_ids schreibt im DRY_RUN nichts' do
    create(:club, name: 'SV Trocken')
    referee = create(:referee, lizenznummer: 900_012, nachname: 'Tro', vorname: 'Cken', club_id: nil)
    write_csv('900012;Tro;Cken;;SV Trocken;NRW;1;L2;2024')

    fill_club_ids

    assert_nil referee.reload.club_id
  end
end
