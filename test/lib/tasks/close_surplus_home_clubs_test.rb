require 'test_helper'
require 'rake'
require 'csv'

# Tests fuer players:close_surplus_home_clubs
# (lib/tasks/close_surplus_home_clubs.rake): schliesst je Profil den ueberzaehligen
# offenen Heimatverein, den ein Merge vor api#481 stehengelassen hat. Die Entscheidung
# je Profil kommt aus einer CSV, nicht aus einer Regel im Code.
class CloseSurplusHomeClubsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['players:close_surplus_home_clubs']
    @task.reenable

    create(:setting, current_season_id: '18')
    @behalten = create(:club)
    @schliessen = create(:club)
  end

  teardown { File.delete(@csv) if @csv && File.exist?(@csv) }

  def liste(zeilen)
    @csv = Rails.root.join("tmp/close_surplus_test_#{SecureRandom.hex(4)}.csv").to_s
    CSV.open(@csv, 'w', col_sep: ';') do |csv|
      csv << %w[player_id behalten schliessen beleg]
      zeilen.each { |z| csv << z }
    end
    @csv
  end

  def run_task(pfad, dry_run: false)
    env = { 'CSV' => pfad, 'DRY_RUN' => dry_run ? 'true' : 'false' }
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def profil(eintraege)
    create(:player, clubs: eintraege)
  end

  def offen(player)
    player.reload.clubs.select { |c| c.is_a?(Hash) && c['valid_until'].blank? }.map { |c| c['club_id'] }
  end

  test 'schliesst den ueberzaehligen Heimatverein' do
    p = profil([{ 'club_id' => @behalten.id, 'home_club' => true },
                { 'club_id' => @schliessen.id, 'home_club' => true }])

    run_task(liste([[p.id, @behalten.id, @schliessen.id, 'Test']]))

    assert_equal [@behalten.id], offen(p)
  end

  test 'Dry-Run schreibt nichts' do
    p = profil([{ 'club_id' => @behalten.id, 'home_club' => true },
                { 'club_id' => @schliessen.id, 'home_club' => true }])

    run_task(liste([[p.id, @behalten.id, @schliessen.id, 'Test']]), dry_run: true)

    assert_equal [@behalten.id, @schliessen.id].sort, offen(p).sort
  end

  # Im Bestand steht club_id teils als String. Ohne durchgehendes to_i wirft schon der
  # Soll-Ist-Vergleich, und zwar ausserhalb der Fehlerbehandlung -- der Lauf risse dann
  # mitten in den Profilen ab, mit den bis dahin geschriebenen Aenderungen im Bestand.
  test 'club_id als String bricht den Lauf nicht ab' do
    p = profil([{ 'club_id' => @behalten.id.to_s, 'home_club' => true },
                { 'club_id' => @schliessen.id, 'home_club' => true }])

    assert_nothing_raised { run_task(liste([[p.id, @behalten.id, @schliessen.id, 'Test']])) }
    assert_equal [@behalten.id.to_s], offen(p)
  end

  # Der Lauf soll ausschliesslich den ueberzaehligen HEIMATverein schliessen. Ein
  # Zweitspielrecht beim selben Verein ist eine eigene Berechtigung.
  test 'ein offenes Zweitspielrecht beim selben Verein bleibt unberuehrt' do
    p = profil([{ 'club_id' => @behalten.id, 'home_club' => true },
                { 'club_id' => @schliessen.id, 'home_club' => true },
                { 'club_id' => @schliessen.id, 'home_club' => false }])

    run_task(liste([[p.id, @behalten.id, @schliessen.id, 'Test']]))
    p.reload

    heimat = p.clubs.find { |c| c['club_id'] == @schliessen.id && c['home_club'] }
    zweit  = p.clubs.find { |c| c['club_id'] == @schliessen.id && !c['home_club'] }
    assert_not_nil heimat['valid_until'], 'der Heimateintrag muss geschlossen sein'
    assert_nil zweit['valid_until'], 'das Zweitspielrecht muss offen bleiben'
  end

  # Bleibt nur noch einer offen, es ist aber der falsche, haengt das Profil weiter am
  # falschen Verein. Das darf der Lauf nicht als "bereits in Ordnung" durchwinken.
  test 'meldet, wenn nur noch der falsche Verein offen ist' do
    p = profil([{ 'club_id' => @behalten.id, 'home_club' => true,
                  'valid_until' => 1.year.ago.iso8601 },
                { 'club_id' => @schliessen.id, 'home_club' => true }])

    aus, = run_task(liste([[p.id, @behalten.id, @schliessen.id, 'Test']]))

    assert_match(/bitte pruefen/, aus)
    assert_match(/1 mit abweichender Lage/, aus)
  end

  test 'weicht die Lage ab, wird uebersprungen statt geraten' do
    fremd = create(:club)
    p = profil([{ 'club_id' => @behalten.id, 'home_club' => true },
                { 'club_id' => fremd.id, 'home_club' => true }])

    aus, = run_task(liste([[p.id, @behalten.id, @schliessen.id, 'Test']]))

    assert_match(/Lage weicht ab/, aus)
    assert_equal [@behalten.id, fremd.id].sort, offen(p).sort
  end

  test 'zweiter Lauf schreibt nicht erneut' do
    p = profil([{ 'club_id' => @behalten.id, 'home_club' => true },
                { 'club_id' => @schliessen.id, 'home_club' => true }])
    pfad = liste([[p.id, @behalten.id, @schliessen.id, 'Test']])

    run_task(pfad)
    vorher = p.reload.clubs.to_json
    aus, = run_task(pfad)

    assert_equal vorher, p.reload.clubs.to_json
    assert_match(/bereits in Ordnung/, aus)
  end

  test 'ein kaputter clubs-Eintrag bricht den Lauf nicht ab' do
    p = profil([{ 'club_id' => @behalten.id, 'home_club' => true },
                { 'club_id' => @schliessen.id, 'home_club' => true }])
    p.clubs = p.clubs + [nil]
    p.save!(validate: false)

    assert_nothing_raised { run_task(liste([[p.id, @behalten.id, @schliessen.id, 'Test']])) }
    assert_equal [@behalten.id], offen(p)
  end

  test 'unbekannte Spieler-ID wird gemeldet' do
    aus, = run_task(liste([[999_999_999, @behalten.id, @schliessen.id, 'Test']]))

    assert_match(/Profil nicht gefunden/, aus)
    assert_match(/1 Fehler/, aus)
  end

  test 'die mitgelieferte Liste ist wohlgeformt' do
    pfad = Rails.root.join('lib/tasks/data/doppelte_heimatvereine_2026_08_18.csv')
    zeilen = CSV.read(pfad, headers: true, col_sep: ';')

    assert_equal %w[player_id behalten schliessen beleg], zeilen.headers
    assert zeilen.any?, 'Liste darf nicht leer sein'
    assert_equal zeilen.size, zeilen.map { |z| z['player_id'] }.uniq.size, 'keine doppelte Spieler-ID'
    zeilen.each do |z|
      assert_not_equal z['behalten'], z['schliessen'], "##{z['player_id']}: behalten == schliessen"
      assert_match(/\A\d+\z/, z['behalten'].to_s)
      z['schliessen'].to_s.split(',').each { |id| assert_match(/\A\d+\z/, id) }
    end
  end
end
