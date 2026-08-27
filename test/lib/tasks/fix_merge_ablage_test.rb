require 'test_helper'
require 'rake'
require 'csv'

# Tests fuer players:fix_merge_ablage (lib/tasks/fix_merge_ablage.rake): holt die Profile
# aus den Ablage-Vereinen zurueck, in denen eine Zusammenlegung sie haengen gelassen hat.
# Die Entscheidung je Profil kommt aus einer CSV, nicht aus einer Regel im Code.
class FixMergeAblageTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['players:fix_merge_ablage']
    @task.reenable

    create(:setting, current_season_id: '18')
    @user = create(:user)
    @ablage = create(:club, name: 'Ablage Doppelung')
    @verein = create(:club, name: 'UHC Elster')
  end

  teardown { File.delete(@csv) if @csv && File.exist?(@csv) }

  def liste(zeilen)
    @csv = Rails.root.join("tmp/fix_merge_ablage_test_#{SecureRandom.hex(4)}.csv").to_s
    CSV.open(@csv, 'w', col_sep: ';') do |csv|
      csv << %w[player_id aktion ablage oeffnen beleg]
      zeilen.each { |z| csv << z }
    end
    @csv
  end

  # Eigene Ausgabe-Umleitung statt `capture_io`: Der Lauf beendet sich bei einem Fehler mit
  # `exit 1`, damit ein Fehler in einem gruen wirkenden Lauf nicht untergeht. `capture_io`
  # verliert die Ausgabe, sobald der Block wirft -- und genau die Meldung will der Test
  # lesen. Rueckgabe: [Ausgabe, Exit-Status oder nil].
  def run_task(pfad, dry_run: false, user_id: nil)
    env = { 'CSV' => pfad, 'DRY_RUN' => dry_run ? 'true' : 'false',
            'USER_ID' => (user_id || @user.id).to_s }
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    puffer = StringIO.new
    original = $stdout
    $stdout = puffer
    status = nil
    begin
      @task.reenable
      @task.invoke
    rescue SystemExit => e
      status = e.status
    end
    [puffer.string, status]
  ensure
    $stdout = original
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def offen(player)
    eintraege = player.reload.clubs.select do |c|
      c.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
    end
    eintraege.map { |c| c['club_id'] }
  end

  def eintrag(player, club_id)
    player.reload.clubs.select { |c| c.is_a?(Hash) && c['club_id'].to_i == club_id }
  end

  # Der Fall aus der Meldung: 4876 hing in "Ablage Doppelung", der Eintrag war eine Kopie
  # aus der Dublette, sein UHC-Elster-Eintrag war seit Jahren geschlossen.
  test 'entfernen loescht den Ablage-Eintrag und oeffnet den belegten Verein' do
    p = create(:player, clubs: [
      { 'club_id' => @verein.id, 'home_club' => true, 'valid_until' => 4.years.ago.iso8601 },
      { 'club_id' => @ablage.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 }
    ])

    run_task(liste([[p.id, 'entfernen', @ablage.id, @verein.id, 'Lizenz S17']]))

    assert_equal [@verein.id], offen(p)
    assert_empty eintrag(p, @ablage.id), 'die Kopie muss ganz verschwinden'
  end

  test 'schliessen behaelt den Ablage-Eintrag als Historie' do
    p = create(:player, clubs: [
      { 'club_id' => @verein.id, 'home_club' => true, 'valid_until' => 4.years.ago.iso8601 },
      { 'club_id' => @ablage.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 }
    ])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Lizenz S17']]))

    assert_equal [@verein.id], offen(p)
    zu = eintrag(p, @ablage.id).first
    assert_not_nil zu, 'der eigene Eintrag bleibt als Historie stehen'
    assert_not_nil zu['valid_until']
    assert_equal @user.id, zu['valid_set_by'], 'der ausfuehrende Benutzer muss dranstehen'
  end

  test 'nur_oeffnen kommt ohne Ablage-Eintrag aus' do
    p = create(:player, clubs: [{ 'club_id' => @verein.id, 'home_club' => true,
                                  'valid_until' => 4.years.ago.iso8601 }])

    run_task(liste([[p.id, 'nur_oeffnen', nil, @verein.id, 'Lizenz S12']]))

    assert_equal [@verein.id], offen(p)
  end

  # Das created_at traegt den Beginn der Mitgliedschaft, und `Player#home_club` wie
  # `_merge_clubs` lesen danach. Ein neuer Eintrag von heute wuerde behaupten, die
  # Mitgliedschaft habe heute begonnen.
  test 'der wiedereroeffnete Eintrag behaelt seinen Beginn' do
    beginn = 9.years.ago.iso8601
    p = create(:player, clubs: [
      { 'club_id' => @verein.id, 'home_club' => true, 'created_at' => beginn,
        'valid_until' => 4.years.ago.iso8601, 'valid_set_by' => 500 },
      { 'club_id' => @ablage.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 }
    ])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    auf = eintrag(p, @verein.id).first
    assert_equal beginn, auf['created_at']
    assert_nil auf['valid_set_by'], 'die alte Schliessung darf keine Spur hinterlassen'
    assert_equal 'merge_ablage_fix', auf['source']
    assert_equal 1, eintrag(p, @verein.id).size, 'kein zweiter Eintrag desselben Vereins'
  end

  test 'ohne vorhandenen Eintrag wird der Zielverein neu angelegt' do
    p = create(:player, clubs: [{ 'club_id' => @ablage.id, 'home_club' => true,
                                  'created_at' => 2.years.ago.iso8601 }])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    neu = eintrag(p, @verein.id).first
    assert_equal [@verein.id], offen(p)
    assert_equal @user.id, neu['created_by']
    assert_equal 'merge_ablage_fix', neu['source']
  end

  # Gibt es mehrere geschlossene Eintraege desselben Vereins, gewinnt der zuletzt beendete.
  test 'von mehreren Eintraegen desselben Vereins wird der jueangste geoeffnet' do
    p = create(:player, clubs: [
      { 'club_id' => @verein.id, 'home_club' => true, 'created_at' => 9.years.ago.iso8601,
        'valid_until' => 8.years.ago.iso8601 },
      { 'club_id' => @verein.id, 'home_club' => true, 'created_at' => 6.years.ago.iso8601,
        'valid_until' => 4.years.ago.iso8601 },
      { 'club_id' => @ablage.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 }
    ])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    assert_equal [@verein.id], offen(p)
    assert_equal(1, eintrag(p, @verein.id).count { |c| c['valid_until'].blank? })
    juengste = eintrag(p, @verein.id).find { |c| c['valid_until'].blank? }
    assert_equal 6.years.ago.iso8601, juengste['created_at']
  end

  test 'Dry-Run schreibt nichts' do
    p = create(:player, clubs: [{ 'club_id' => @ablage.id, 'home_club' => true,
                                  'created_at' => 2.years.ago.iso8601 }])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]), dry_run: true)

    assert_equal [@ablage.id], offen(p)
  end

  # Der Bestand kann sich seit dem Erstellen der Liste geaendert haben. Dann lieber melden
  # als raten: Ein Profil, das inzwischen einen echten Verein hat, darf der Lauf nicht
  # umschreiben.
  test 'abweichende Lage wird gemeldet und nicht angefasst' do
    anderer = create(:club, name: 'SC DHfK Leipzig')
    p = create(:player, clubs: [{ 'club_id' => anderer.id, 'home_club' => true }])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    assert_equal [anderer.id], offen(p)
  end

  # Ein zweiter Lauf am selben Tag ist der wahrscheinliche Fall (Dry-Run, pruefen, echt
  # laufen, nochmal pruefen). `open_home_club_entries` wertet tagesgenau und saehe die
  # gerade geschlossene Ablage weiter als offen -- ohne die strenge Pruefung legte der
  # Lauf den Zielverein ein zweites Mal an.
  test 'ein zweiter Lauf aendert nichts mehr' do
    p = create(:player, clubs: [
      { 'club_id' => @verein.id, 'home_club' => true, 'valid_until' => 4.years.ago.iso8601 },
      { 'club_id' => @ablage.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 }
    ])
    zeile = liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']])

    run_task(zeile)
    vorher = p.reload.clubs
    run_task(zeile)

    assert_equal vorher, p.reload.clubs
    assert_equal [@verein.id], offen(p)
    assert_equal 1, eintrag(p, @verein.id).size
  end

  # Ein offenes Zweitspielrecht ist kein Heimatverein und geht den Lauf nichts an.
  test 'ein offenes Zweitspielrecht bleibt unberuehrt' do
    zweit = create(:club, name: 'SC DHfK Leipzig')
    p = create(:player, clubs: [
      { 'club_id' => @ablage.id, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 },
      { 'club_id' => zweit.id, 'home_club' => false }
    ])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    assert_equal [@verein.id], offen(p)
    assert_nil eintrag(p, zweit.id).first['valid_until'], 'das Zweitspielrecht bleibt offen'
  end

  # Im Bestand steht club_id teils als String. Ohne durchgehendes to_i meldete der Lauf
  # jede Zeile als abweichend und tut nichts.
  test 'club_id als String wird erkannt' do
    p = create(:player, clubs: [
      { 'club_id' => @verein.id.to_s, 'home_club' => true, 'valid_until' => 4.years.ago.iso8601 },
      { 'club_id' => @ablage.id.to_s, 'home_club' => true, 'created_at' => 2.years.ago.iso8601 }
    ])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    assert_equal [@verein.id.to_s], offen(p)
  end

  # home_club als String ist im Altbestand der Normalfall.
  test 'home_club als String zaehlt als Heimatverein' do
    p = create(:player, clubs: [{ 'club_id' => @ablage.id, 'home_club' => 'true',
                                  'created_at' => 2.years.ago.iso8601 }])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    assert_equal [@verein.id], offen(p)
  end

  test 'ein Eintrag ohne Struktur bricht den Lauf nicht ab' do
    p = create(:player, clubs: [nil, { 'club_id' => @ablage.id, 'home_club' => true,
                                       'created_at' => 2.years.ago.iso8601 }])

    run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    assert_equal [@verein.id], offen(p)
  end

  test 'eine unbekannte Aktion wird als Fehler gemeldet und schreibt nichts' do
    p = create(:player, clubs: [{ 'club_id' => @ablage.id, 'home_club' => true,
                                  'created_at' => 2.years.ago.iso8601 }])

    out, status = run_task(liste([[p.id, 'verschieben', @ablage.id, @verein.id, 'Beleg']]))

    assert_equal [@ablage.id], offen(p)
    assert_match(/FEHLER/, out)
    assert_equal 1, status, 'ein Fehler muss den Lauf mit Exit-Code 1 beenden'
  end

  test 'ein unbekanntes Profil wird gemeldet' do
    out, status = run_task(liste([[999_999_999, 'schliessen', @ablage.id, @verein.id, 'Beleg']]))

    assert_match(/nicht gefunden/, out)
    assert_equal 1, status
  end

  # Ohne Benutzer fehlt die Spur, wer den Eintrag geschlossen hat, und genau die braucht
  # `unmerge_from!`, um eine Zugehoerigkeit spaeter wieder zuordnen zu koennen.
  test 'ein echter Lauf ohne USER_ID bricht ab, bevor er schreibt' do
    p = create(:player, clubs: [{ 'club_id' => @ablage.id, 'home_club' => true,
                                  'created_at' => 2.years.ago.iso8601 }])

    _out, status = run_task(liste([[p.id, 'schliessen', @ablage.id, @verein.id, 'Beleg']]), user_id: '')

    assert_equal [@ablage.id], offen(p)
    assert_equal 1, status
  end
end
