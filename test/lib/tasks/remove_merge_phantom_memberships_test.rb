require 'test_helper'
require 'rake'
require 'csv'

# Tests fuer players:remove_merge_phantom_memberships
# (lib/tasks/remove_merge_phantom_memberships.rake): entfernt Vereinszugehoerigkeiten, die
# eine Zusammenlegung von einer Fehlanlage auf das echte Profil kopiert hat und die eine
# Mitgliedschaft behaupten, die es nie gab. Welche Eintraege das sind, steht einzeln belegt
# in einer CSV und nicht in einer Regel im Code.
class RemoveMergePhantomMembershipsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['players:remove_merge_phantom_memberships']
    @task.reenable

    create(:setting, current_season_id: '18')
    @user = create(:user)
    @elster = create(:club, name: 'UHC Elster')
    @weissenfels = create(:club, name: 'UHC Weissenfels')
  end

  teardown { File.delete(@csv) if @csv && File.exist?(@csv) }

  def liste(zeilen)
    @csv = Rails.root.join("tmp/phantom_test_#{SecureRandom.hex(4)}.csv").to_s
    CSV.open(@csv, 'w', col_sep: ';') do |csv|
      csv << %w[player_id club von bis anzahl soll_offen beleg]
      zeilen.each { |z| csv << z }
    end
    @csv
  end

  # Eigene Ausgabe-Umleitung statt `capture_io`: Der Lauf beendet sich bei einem Fehler mit
  # `exit 1`, und `capture_io` verliert die Ausgabe, sobald der Block wirft -- genau die
  # Meldung will der Test aber lesen.
  def run_task(pfad, dry_run: false, user_id: nil)
    env = { 'CSV' => pfad, 'DRY_RUN' => dry_run ? 'true' : 'false',
            'USER_ID' => (user_id || @user.id).to_s }
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    puffer = StringIO.new
    original = $stdout
    original_err = $stderr
    # Auch stderr: `abort` schreibt dorthin, und die Abbruchmeldung ist genau das, was der
    # Test lesen will.
    $stdout = puffer
    $stderr = puffer
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
    $stderr = original_err
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def offen(player)
    eintraege = player.reload.clubs.select do |c|
      c.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(c['home_club']) && c['valid_until'].blank?
    end
    eintraege.map { |c| c['club_id'] }.sort
  end

  def eintraege_bei(player, club_id)
    player.reload.clubs.select { |c| c.is_a?(Hash) && c['club_id'].to_i == club_id }
  end

  # Der gemeldete Fall 4876: acht Tage bei einem Verein, dem er nie angehoert hat, dazu die
  # echte Freigabe an denselben Verein. Nur die Phantom-Heimat darf verschwinden.
  def brueckner
    create(:player, clubs: [
      { 'club_id' => @elster.id, 'home_club' => true },
      { 'club_id' => @weissenfels.id, 'home_club' => true,
        'created_at' => '2021-09-08T16:03:34+02:00',
        'valid_until' => '2021-09-16T22:56:43+02:00' },
      { 'club_id' => @weissenfels.id, 'home_club' => false,
        'created_at' => '2021-09-15T07:38:33+02:00',
        'valid_until' => '2022-07-15T00:00:00+02:00' }
    ])
  end

  def brueckner_zeile(player)
    [player.id, @weissenfels.id, '2021-09-08T16:03:34', '2021-09-16T22:56:43', 1,
     @elster.id, 'Anlage der Dublette']
  end

  test 'die Phantom-Mitgliedschaft verschwindet, die echte Freigabe bleibt' do
    p = brueckner

    run_task(liste([brueckner_zeile(p)]))

    bei_wsf = eintraege_bei(p, @weissenfels.id)
    assert_equal 1, bei_wsf.size, "nur die Freigabe darf bleiben: #{bei_wsf.inspect}"
    assert_equal false, ActiveModel::Type::Boolean.new.cast(bei_wsf.first['home_club'])
    assert_equal [@elster.id], offen(p)
  end

  test 'der Dry-Run schreibt nichts' do
    p = brueckner

    ausgabe, = run_task(liste([brueckner_zeile(p)]), dry_run: true)

    assert_equal 2, eintraege_bei(p, @weissenfels.id).size
    assert_match(/Dry-Run/, ausgabe)
    assert_match(/1 Profil\(e\) zu bereinigen/, ausgabe)
  end

  test 'ein zweiter Lauf aendert nichts mehr' do
    p = brueckner
    pfad = liste([brueckner_zeile(p)])

    run_task(pfad)
    ausgabe, status = run_task(pfad)

    assert_nil status
    assert_match(/0 Profil\(e\) bereinigt, 1 bereits in Ordnung/, ausgabe)
    assert_equal 1, eintraege_bei(p, @weissenfels.id).size
  end

  # 11562 traegt die kopierte Zugehoerigkeit zweimal identisch. Eine Array-Differenz haette
  # fuer einen Treffer beide entfernt, deshalb steht die erwartete Zahl in der Liste.
  test 'zwei identische Kopien werden beide entfernt, wenn die Liste zwei ankuendigt' do
    kopie = { 'club_id' => @weissenfels.id, 'home_club' => true,
              'created_at' => '2024-10-29T17:41:23+02:00',
              'valid_until' => '2024-11-05T13:19:51+01:00' }
    p = create(:player, clubs: [{ 'club_id' => @elster.id, 'home_club' => true },
                                kopie.dup, kopie.dup])

    run_task(liste([[p.id, @weissenfels.id, '2024-10-29T17:41:23', '2024-11-05T13:19:51', 2,
                     @elster.id, 'doppelt kopiert']]))

    assert_empty eintraege_bei(p, @weissenfels.id)
    assert_equal [@elster.id], offen(p)
  end

  test 'kuendigt die Liste eine andere Trefferzahl an, wird die Zeile uebersprungen' do
    p = brueckner
    zeile = brueckner_zeile(p)
    zeile[4] = 2

    ausgabe, = run_task(liste([zeile]))

    assert_equal 2, eintraege_bei(p, @weissenfels.id).size
    assert_match(/Lage weicht ab \(1 statt 2 Treffer/, ausgabe)
    assert_match(/1 mit abweichender Lage/, ausgabe)
  end

  # Die drei deaktivierten Profile der Liste haben danach gar keinen offenen Heimatverein
  # mehr, und das ist der richtige Zustand. Eine leere Spalte muss das ausdruecken koennen.
  test 'ein offener Ablage-Eintrag darf entfernt werden und laesst nichts offen zurueck' do
    ablage = create(:club, name: 'Ablage Doppelung')
    p = create(:player, clubs: [
      { 'club_id' => @elster.id, 'home_club' => true,
        'created_at' => '2015-01-01T10:00:00+01:00',
        'valid_until' => '2026-07-17T18:30:23+02:00' },
      { 'club_id' => ablage.id, 'home_club' => true,
        'created_at' => '2015-09-09T16:06:38+02:00' }
    ])

    run_task(liste([[p.id, ablage.id, '2015-09-09T16:06:38', nil, 1, nil, 'Ablage der Dublette']]))

    assert_empty eintraege_bei(p, ablage.id)
    assert_empty offen(p)
    assert_equal 1, eintraege_bei(p, @elster.id).size, 'die eigene Historie bleibt unangetastet'
  end

  # Der wichtigste Riegel: Wuerde das Entfernen ein Profil ohne Heimatverein zuruecklassen,
  # obwohl die Liste einen ankuendigt, darf nichts geschrieben werden. Sonst faellt eine
  # aktive Person aus der Vereinsliste und ist weder lizenzierbar noch transferierbar.
  test 'ein Profil wird nicht ohne Heimatverein zurueckgelassen' do
    p = create(:player, clubs: [{ 'club_id' => @weissenfels.id, 'home_club' => true,
                                  'created_at' => '2021-09-08T16:03:34+02:00' }])

    ausgabe, = run_task(liste([[p.id, @weissenfels.id, '2021-09-08T16:03:34', nil, 1,
                                @elster.id, 'Anlage der Dublette']]))

    assert_equal 1, eintraege_bei(p, @weissenfels.id).size, 'nichts darf entfernt worden sein'
    assert_match(/Lage weicht ab/, ausgabe)
  end

  # Ein geschlossener Eintrag zaehlt nicht als offen: Wer ihn entfernt, aendert an der
  # offenen Lage nichts, und die Zeile muss trotzdem durchgehen.
  test 'das Entfernen eines geschlossenen Eintrags laesst die offene Lage unberuehrt' do
    p = brueckner

    run_task(liste([brueckner_zeile(p)]))

    assert_equal [@elster.id], offen(p)
  end

  # Praefix-Vergleich: Die Zeitstempel liegen in verschiedenen Schreibweisen vor, mit und
  # ohne Bruchteile, mit unterschiedlichem UTC-Versatz.
  test 'der Zeitstempel wird als Praefix verglichen' do
    p = create(:player, clubs: [
      { 'club_id' => @elster.id, 'home_club' => true },
      { 'club_id' => @weissenfels.id, 'home_club' => true,
        'created_at' => '2021-09-08T16:03:34.918+02:00',
        'valid_until' => '2021-09-16T22:56:43.221+02:00' }
    ])

    run_task(liste([brueckner_zeile(p)]))

    assert_empty eintraege_bei(p, @weissenfels.id)
  end

  # Gegenprobe dazu: Eine andere Sekunde ist ein anderer Eintrag und wird nicht getroffen.
  # Der Dry-Run muss das melden -- dort kann "kein Treffer" noch nicht bedeuten, dass der
  # Eintrag schon entfernt wurde, also ist es ein Fehler in der Liste.
  test 'ein Eintrag aus einer anderen Sekunde wird nicht getroffen' do
    p = create(:player, clubs: [
      { 'club_id' => @elster.id, 'home_club' => true },
      { 'club_id' => @weissenfels.id, 'home_club' => true,
        'created_at' => '2021-09-08T16:03:35+02:00',
        'valid_until' => '2021-09-16T22:56:43+02:00' }
    ])
    pfad = liste([brueckner_zeile(p)])

    vorlauf, = run_task(pfad, dry_run: true)
    assert_match(/kein Eintrag zu dieser Zeile gefunden/, vorlauf)
    assert_match(/1 mit abweichender Lage/, vorlauf)

    run_task(pfad)
    assert_equal 1, eintraege_bei(p, @weissenfels.id).size
  end

  test 'ein unbekanntes Profil meldet einen Fehler und setzt den Exit-Code' do
    ausgabe, status = run_task(liste([[999_999, @weissenfels.id, '2021-09-08T16:03:34',
                                       '2021-09-16T22:56:43', 1, @elster.id, 'x']]))

    assert_equal 1, status
    assert_match(/Profil nicht gefunden/, ausgabe)
  end

  test 'ohne USER_ID laeuft nichts' do
    p = brueckner

    ausgabe, status = run_task(liste([brueckner_zeile(p)]), user_id: '')

    assert_equal 1, status
    assert_match(/USER_ID fehlt/, ausgabe)
    assert_equal 2, eintraege_bei(p, @weissenfels.id).size
  end

  test 'der Lauf vermerkt den ausfuehrenden Benutzer am Profil' do
    p = brueckner

    run_task(liste([brueckner_zeile(p)]))

    assert_equal @user.id, p.reload.updated_by
  end

  # Die mitgelieferte Liste ist Bestandteil des Laufs und muss zu seinen Spalten passen.
  test 'die mitgelieferte Liste ist lesbar und vollstaendig' do
    pfad = Rails.root.join('lib/tasks/data/merge_phantom_memberships_2026_08_27.csv')
    zeilen = CSV.read(pfad, headers: true, col_sep: ';')

    assert_equal %w[player_id club von bis anzahl soll_offen beleg], zeilen.headers
    assert_equal 5, zeilen.size
    zeilen.each do |z|
      assert_match(/\A\d+\z/, z['player_id'].to_s, z.inspect)
      assert_match(/\A\d+\z/, z['club'].to_s, z.inspect)
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\z/, z['von'].to_s, z.inspect)
      assert_match(/\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})?\z/, z['bis'].to_s, z.inspect)
      assert_operator z['anzahl'].to_i, :>=, 1, z.inspect
      assert_predicate z['beleg'].to_s.length, :positive?, z.inspect
    end
  end
end
