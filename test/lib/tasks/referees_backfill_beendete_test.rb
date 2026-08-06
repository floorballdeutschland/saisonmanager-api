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
  end

  teardown do
    @csv.close!
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
    run_task('referees2025:backfill_beendete', { 'CSV' => @csv.path }.merge(env))
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

    out, = run_task('referees2025:fill_club_ids', { 'CSV' => @csv.path, 'DRY_RUN' => 'false' })

    assert_equal neu.id, ohne.reload.club_id, 'long_name-Treffer füllt die leere Zuordnung'
    assert_equal alt.id, gesetzt.reload.club_id, 'gesetzte Zuordnung bleibt unangetastet'
    assert_match(/davon Widerspruch zur Excel:\s+1/, out)
  end

  test 'fill_club_ids schreibt im DRY_RUN nichts' do
    create(:club, name: 'SV Trocken')
    referee = create(:referee, lizenznummer: 900_012, nachname: 'Tro', vorname: 'Cken', club_id: nil)
    write_csv('900012;Tro;Cken;;SV Trocken;NRW;1;L2;2024')

    run_task('referees2025:fill_club_ids', { 'CSV' => @csv.path })

    assert_nil referee.reload.club_id
  end
end
