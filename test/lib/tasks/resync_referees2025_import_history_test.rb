require 'test_helper'
require 'rake'

# Smoke-Tests für referees2025:import_history. Der Task hatte bisher gar keine
# Abdeckung — und lief nach dem Umbau der Vereinssuche in einen NameError, weil
# ein Aufrufer der entfernten Lambda übersehen worden war. Das fällt nur auf,
# wenn mindestens eine Zeile einen Schiedsrichter trifft.
class ResyncReferees2025ImportHistoryTest < ActiveSupport::TestCase
  HEADER = 'lizenznummer;nachname;vorname;geburtsdatum;verein;jahr;' \
           'kurs1_stufe;kurs1_datum;kurs1_testversion;kurs1_punkte;' \
           'kurs2_stufe;kurs2_datum;kurs2_testversion;kurs2_punkte;lizenz'.freeze
  HEADER_BEENDET = "#{HEADER};unvollstaendig".freeze

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting)
    @admin = create(:user, :admin)
    @csv = Tempfile.new(['historie', '.csv'])
  end

  teardown do
    @csv.close!
  end

  def write_csv(header, *zeilen)
    @csv.write([header, *zeilen].join("\n"))
    @csv.flush
    @csv.path
  end

  def run_import(env = {})
    task = Rake::Task['referees2025:import_history']
    defaults = { 'HISTORY_CSV' => @csv.path, 'UPLOADED_BY' => @admin.user_name }
    env = defaults.merge(env)
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  test 'legt Kursergebnisse für vorhandene Schiedsrichter an' do
    create(:referee, lizenznummer: 950_001, nachname: 'Historisch', vorname: 'Hanna',
                     geburtsdatum: Date.new(1985, 3, 3))
    write_csv(HEADER, '950001;Historisch;Hanna;03.03.1985;;2019;F;03.08.2019;F-19-1;46;;;;;L2')

    assert_difference -> { RefereeCourseResult.count }, 1 do
      run_import
    end

    result = RefereeCourseResult.last

    assert_equal 950_001, result.csv_lizenznummer
    assert_equal 'applied', result.status
  end

  test 'ordnet den Verein auch über den long_name zu' do
    club = create(:club, name: 'SSF Bonn', long_name: 'SSF Bonn 1905 e.V.')
    create(:referee, lizenznummer: 950_002, nachname: 'Lang', vorname: 'Lena')
    write_csv(HEADER, '950002;Lang;Lena;;SSF Bonn 1905 e.V.;2019;F;03.08.2019;F-19-1;46;;;;;L2')

    run_import

    assert_equal club.id, RefereeCourseResult.last.master_club_id_final
  end

  test 'BATCH_SUFFIX trennt den Lauf der Beendeten von dem der Aktiven' do
    create(:referee, lizenznummer: 950_003, nachname: 'Beendet', vorname: 'Bert')
    write_csv(HEADER, '950003;Beendet;Bert;;;2019;F;03.08.2019;F-19-1;46;;;;;L2')
    run_import

    # Zweiter Lauf mit eigenem Zusatz: derselbe Jahrgang, anderer Batch-Name.
    assert_difference -> { RefereeCourseImport.count }, 1 do
      run_import('BATCH_SUFFIX' => '(Karriere beendet)')
    end

    assert_includes RefereeCourseImport.last.filename, '(Karriere beendet)'
  end

  test 'die Historien-Datei der Beendeten leitet den Zusatz selbst ab' do
    create(:referee, lizenznummer: 950_004, nachname: 'Auto', vorname: 'Anna')
    write_csv(HEADER_BEENDET, '950004;Auto;Anna;;;2019;F;03.08.2019;F-19-1;46;;;;;L2;1')

    run_import

    assert_includes RefereeCourseImport.last.filename, '(Karriere beendet)'
  end

  test 'zweiter Lauf mit demselben Zusatz legt nichts an' do
    create(:referee, lizenznummer: 950_005, nachname: 'Doppelt', vorname: 'Dora')
    write_csv(HEADER, '950005;Doppelt;Dora;;;2019;F;03.08.2019;F-19-1;46;;;;;L2')
    run_import

    assert_no_difference -> { RefereeCourseResult.count } do
      assert_raises(SystemExit) { run_import }
    end
  end

  # Ohne diesen Abbruch sähe ein Lauf, bei dem jeder Jahrgang mit dem bereits
  # importierten Batch der Aktiven kollidiert, wie erfolgreiche Idempotenz aus —
  # und kein einziger der Beendeten bekäme seine Historie.
  test 'ein Lauf ohne einen einzigen importierten Jahrgang bricht ab' do
    create(:referee, lizenznummer: 950_006, nachname: 'Leer', vorname: 'Lars')
    write_csv(HEADER, '950006;Leer;Lars;;;2019;F;03.08.2019;F-19-1;46;;;;;L2')
    run_import

    error = assert_raises(SystemExit) { run_import }

    assert_match(/ABBRUCH/, error.message)
    assert_match(/BATCH_SUFFIX/, error.message)
  end
end
