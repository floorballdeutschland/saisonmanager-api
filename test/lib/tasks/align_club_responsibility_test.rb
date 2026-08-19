require 'test_helper'
require 'rake'
require 'csv'

# Tests fuer clubs:fbh_under_flvsh und clubs:responsibility_report
# (lib/tasks/align_club_responsibility.rake).
#
# Der erste Task haengt den Floorball Bund Hamburg unter den FLV-SH, damit die
# sechs Hamburger Vereine nach der Umstellung einen zustaendigen Spielbetrieb
# haben. Ohne ihn koennte fuer sie niemand berechtigt werden: `permissions`
# kennen nur `game_operation_id`, und Hamburg hat keinen Spielbetrieb.
#
# Verbaende werden hier ueber ihre Kuerzel angelegt, weil der Task sie so sucht.
class AlignClubResponsibilityTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')

    @flvsh = create(:state_association, name: 'Floorballverband Schleswig-Holstein e.V.',
                                        short_name: 'FLV-SH', sbk_email: 'sbk@floorball-sh.example')
    @flvsh_go = create(:game_operation, state_association_id: @flvsh.id)
    @fbh = create(:state_association, name: 'Floorball Bund Hamburg e.V.', short_name: 'FBH',
                                      sbk_email: 'info@floorball.hamburg',
                                      vsk_email: 'info@floorball.hamburg',
                                      rsk_email: 'info@floorball.hamburg')
  end

  teardown { File.delete(@csv) if @csv && File.exist?(@csv) }

  def run_task(name, dry_run: false)
    task = Rake::Task[name]
    saved = ENV.fetch('DRY_RUN', nil)
    ENV['DRY_RUN'] = dry_run ? 'true' : 'false'
    task.reenable
    capture_io { task.invoke }
  ensure
    ENV['DRY_RUN'] = saved
  end

  test 'haengt FBH unter den FLV-SH und macht dessen Spielbetrieb zustaendig' do
    club = create(:club, state_association_id: @fbh.id)
    assert_nil club.main_game_operation_id, 'Ausgangslage: kein Verband zustaendig'

    run_task('clubs:fbh_under_flvsh')

    assert_equal @flvsh.id, @fbh.reload.parent_id
    assert_equal @flvsh_go.id, club.reload.main_game_operation_id
  end

  # Die Postfaecher sollen auf den FLV-SH zurueckfallen. Das tun sie nur bei
  # leerem eigenem Feld (StateAssociation#effective_sbk_email und Geschwister) --
  # ein eigener Eintrag am Kind gewinnt und haette die Post weiter nach Hamburg
  # geschickt, obwohl zustaendig der FLV-SH ist.
  test 'leert die Postfaecher, damit sie vom FLV-SH geerbt werden' do
    run_task('clubs:fbh_under_flvsh')
    @fbh.reload

    assert_nil @fbh.sbk_email
    assert_nil @fbh.vsk_email
    assert_nil @fbh.rsk_email
    assert_equal 'sbk@floorball-sh.example', @fbh.effective_sbk_email
  end

  test 'Dry-Run schreibt nichts' do
    run_task('clubs:fbh_under_flvsh', dry_run: true)
    @fbh.reload

    assert_nil @fbh.parent_id
    assert_equal 'info@floorball.hamburg', @fbh.sbk_email
  end

  # Ohne Spielbetrieb am Ziel waere Hamburg nach dem Lauf genauso herrenlos wie
  # vorher, nur mit einem Elternverband. Der Task bricht dann ab, statt eine
  # Aenderung zu schreiben, die ihren Zweck verfehlt.
  test 'bricht ab, wenn der FLV-SH keinen Spielbetrieb hat' do
    @flvsh_go.destroy!

    assert_raises(SystemExit) { run_task('clubs:fbh_under_flvsh') }
    assert_nil @fbh.reload.parent_id
  end

  # --- clubs:fix_state_associations ------------------------------------------
  #
  # Korrigiert die Landesverbands-Zuordnung aus einer Liste. Die Entscheidung je
  # Verein ist belegt, nicht hergeleitet, deshalb eine CSV und keine Regel.

  def liste(zeilen)
    @csv = Rails.root.join("tmp/lv_korrektur_test_#{SecureRandom.hex(4)}.csv").to_s
    CSV.open(@csv, 'w', col_sep: ';') do |csv|
      csv << %w[club_id name lv_kuerzel state beleg]
      zeilen.each { |z| csv << z }
    end
    @csv
  end

  def run_fix(pfad, dry_run: false)
    task = Rake::Task['clubs:fix_state_associations']
    saved = ENV.to_hash.slice('CSV', 'DRY_RUN')
    ENV['CSV'] = pfad
    ENV['DRY_RUN'] = dry_run ? 'true' : 'false'
    task.reenable
    capture_io { task.invoke }
  ensure
    %w[CSV DRY_RUN].each { |k| ENV[k] = saved[k] }
  end

  test 'setzt den Landesverband und damit den zustaendigen Spielbetrieb' do
    ziel_sa = create(:state_association, short_name: 'ZIEL')
    ziel_go = create(:game_operation, state_association_id: ziel_sa.id)
    club = create(:club, name: 'Wechsler', state_association_id: @fbh.id)

    run_fix(liste([[club.id, 'Wechsler', 'ZIEL', '', 'Test']]))

    club.reload
    assert_equal ziel_sa.id, club.state_association_id
    assert_equal ziel_go.id, club.main_game_operation_id
  end

  # Leeres state-Feld heisst „unveraendert lassen", nicht „leeren". Bei den
  # Trophy-Auswahlteams traegt das Bundesland die vertretene Region und muss
  # stehenbleiben, waehrend der Landesverband auf den Bundesverband wechselt.
  test 'laesst das Bundesland stehen, wenn die Liste keines nennt' do
    ziel_sa = create(:state_association, short_name: 'ZIEL')
    create(:game_operation, state_association_id: ziel_sa.id)
    club = create(:club, name: 'Auswahl Nord', state: 'de-sh', state_association_id: @fbh.id)

    run_fix(liste([[club.id, 'Auswahl Nord', 'ZIEL', '', 'Auswahlteam']]))

    assert_equal 'de-sh', club.reload.state, 'die vertretene Region darf nicht verlorengehen'
  end

  test 'setzt das Bundesland, wenn die Liste eines nennt' do
    ziel_sa = create(:state_association, short_name: 'ZIEL')
    create(:game_operation, state_association_id: ziel_sa.id)
    club = create(:club, name: 'Falsch verortet', state: 'de-be', state_association_id: @fbh.id)

    run_fix(liste([[club.id, 'Falsch verortet', 'ZIEL', 'de-sn', 'Sitz korrigiert']]))

    assert_equal 'de-sn', club.reload.state
  end

  # Der Name in der Liste ist eine Sicherung: Steht unter der ID inzwischen ein
  # anderer Verein (Merge, Neuanlage), ist die Entscheidung nicht mehr belegt.
  # Ohne diese Pruefung wuerde der Lauf einem fremden Verein einen Verband
  # zuweisen, den nie jemand fuer ihn entschieden hat.
  test 'ueberspringt einen Verein, dessen Name nicht zur Liste passt' do
    ziel_sa = create(:state_association, short_name: 'ZIEL')
    create(:game_operation, state_association_id: ziel_sa.id)
    club = create(:club, name: 'Inzwischen anders', state_association_id: @fbh.id)

    out, = run_fix(liste([[club.id, 'Alter Name', 'ZIEL', '', 'Test']]))

    assert_equal @fbh.id, club.reload.state_association_id
    assert_match(/erwartet 'Alter Name'/, out)
    assert_match(/1 Fehler/, out)
  end

  # Ein Ziel ohne Spielbetrieb im Verbund wuerde genau den Zustand herstellen,
  # den die Umstellung beseitigt: ein Verband ist eingetragen, zustaendig ist
  # niemand.
  test 'ueberspringt ein Ziel ohne Spielbetrieb im Verbund' do
    ohne_go = create(:state_association, short_name: 'OHNEGO')
    club = create(:club, name: 'Verein', state_association_id: @flvsh.id)

    out, = run_fix(liste([[club.id, 'Verein', 'OHNEGO', '', 'Test']]))

    assert_equal @flvsh.id, club.reload.state_association_id
    assert_not_equal ohne_go.id, club.state_association_id
    assert_match(/keinen Spielbetrieb/, out)
  end

  test 'fix_state_associations Dry-Run schreibt nichts' do
    ziel_sa = create(:state_association, short_name: 'ZIEL')
    create(:game_operation, state_association_id: ziel_sa.id)
    club = create(:club, name: 'Wechsler', state_association_id: @fbh.id)

    run_fix(liste([[club.id, 'Wechsler', 'ZIEL', '', 'Test']]), dry_run: true)

    assert_equal @fbh.id, club.reload.state_association_id
  end

  # Die mitgelieferte Liste ist der Datenlauf fuer Produktion. Sie muss lesbar
  # sein und darf keine Zeile ohne Beleg enthalten: Der Beleg ist das Einzige,
  # was spaeter erklaert, warum ein Verein diesen Verband hat.
  test 'die mitgelieferte Liste ist vollstaendig belegt' do
    pfad = Rails.root.join('lib/tasks/data/vereins_landesverbaende_2026_08_19.csv')
    zeilen = CSV.read(pfad, headers: true, col_sep: ';')

    assert_equal 23, zeilen.size
    zeilen.each do |z|
      assert z['club_id'].to_i.positive?, "club_id fehlt: #{z.inspect}"
      assert z['name'].present?, "name fehlt: #{z.inspect}"
      assert z['lv_kuerzel'].present?, "lv_kuerzel fehlt: #{z.inspect}"
      assert z['beleg'].present?, "beleg fehlt: #{z.inspect}"
    end
  end

  # Der Bericht ist das Tor vor dem Deploy: Jede Zeile ist ein Verein, der seinen
  # Verband wechselt, ohne dass es jemand angeordnet hat.
  test 'Bericht nennt Vereine, deren Zustaendigkeit sich verschiebt' do
    fremd_go = create(:game_operation, state_association_id: create(:state_association).id)
    # Gespeichert der fremde Spielbetrieb, abgeleitet der des eigenen Verbands:
    # genau die Lage des ETV Hamburg vor der Umstellung.
    wechsler = create(:club, name: 'Wechsler', state_association_id: @flvsh.id,
                             game_operations_hash: [{ 'game_operation_id' => fremd_go.id,
                                                      'home_game_operation' => true }])

    out, = run_task('clubs:responsibility_report')

    assert_match(/Zustaendigkeit wechselt \(1\)/, out)
    assert_match(/#{wechsler.id}\s+Wechsler/, out)
  end

  test 'Bericht nennt Vereine ohne zustaendigen Verband samt Ursache' do
    ohne_lv = create(:club, name: 'Ohne LV', state_association_id: nil)
    verbund_ohne_go = create(:club, name: 'Verbund ohne GO', state_association_id: @fbh.id)

    out, = run_task('clubs:responsibility_report')

    assert_match(/Kein Verband zustaendig \(2\)/, out)
    assert_match(/#{ohne_lv.id}\s+Ohne LV\s+.*kein Landesverband/, out)
    assert_match(/#{verbund_ohne_go.id}\s+Verbund ohne GO\s+.*Verbund ohne Spielbetrieb/, out)
  end
end
