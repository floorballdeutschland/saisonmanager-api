require 'test_helper'
require 'rake'

# Tests für kuerzel:truncate (lib/tasks/truncate_short_names.rake).
#
# Der Task kürzt Bestandswerte auf die neue Länge (Verein 4, Mannschaft 7).
# Vereine, deren gekürztes Kürzel mit einem anderen zusammenfiele, bleiben
# stehen: Ein mehrfach vergebenes Kürzel wäre auf der Anzeigetafel schlimmer
# als ein zu langes. Mannschaften kennen diese Ausnahme nicht, ihr Kürzel wird
# nirgends als Bezeichner gelesen.
class TruncateShortNamesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')
  end

  def run_task(env = {})
    task = Rake::Task['kuerzel:truncate']
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  # update_column, weil die Validierung sonst genau das verhindert, was der
  # Task aufräumen soll.
  def club_mit(kuerzel, name: nil)
    club = create(:club, name: name || "Verein #{SecureRandom.hex(3)}")
    club.update_column(:short_name, kuerzel)
    club
  end

  def team_mit(kuerzel)
    team = create(:team, league: create(:league, :current_season))
    team.update_column(:short_name, kuerzel)
    team
  end

  test 'kuerzt ein zu langes Vereinskuerzel auf vier Zeichen' do
    club = club_mit('Floorball Butzbach')

    run_task('DRY_RUN' => 'false')

    assert_equal 'Floo', club.reload.short_name
  end

  test 'laesst ein Vereinskuerzel in Laenge unangetastet' do
    club = club_mit('ABCD')

    run_task('DRY_RUN' => 'false')

    assert_equal 'ABCD', club.reload.short_name
  end

  test 'kuerzt ein zu langes Mannschaftskuerzel auf sieben Zeichen' do
    team = team_mit('SG Kaufering / Geiselbullach')

    run_task('DRY_RUN' => 'false')

    assert_equal 'SG Kauf', team.reload.short_name
  end

  # Der Kern der Schutzklausel: Aus „U15 Trophy Team Nord" und
  # „U15 Trophy Team Sued" wuerde beidesmal „U15", und die Anzeigetafel
  # koennte die Mannschaften nicht mehr unterscheiden.
  test 'ueberspringt Vereine, deren gekuerztes Kuerzel zusammenfaellt' do
    a = club_mit('U15 Trophy Team Nord')
    b = club_mit('U15 Trophy Team Sued')

    run_task('DRY_RUN' => 'false')

    assert_equal 'U15 Trophy Team Nord', a.reload.short_name
    assert_equal 'U15 Trophy Team Sued', b.reload.short_name
  end

  # Kollision auch dann, wenn der Platz von einem Verein besetzt ist, der selbst
  # gar nicht gekuerzt werden muss.
  test 'ueberspringt auch bei Kollision mit einem bereits kurzen Kuerzel' do
    kurz = club_mit('Floo')
    lang = club_mit('Floorball Butzbach')

    run_task('DRY_RUN' => 'false')

    assert_equal 'Floo', kurz.reload.short_name
    assert_equal 'Floorball Butzbach', lang.reload.short_name, 'darf nicht auf ein belegtes Kuerzel laufen'
  end

  test 'schreibt im Dry-Run nichts' do
    club = club_mit('Floorball Butzbach')
    team = team_mit('SG Kaufering / Geiselbullach')

    run_task

    assert_equal 'Floorball Butzbach', club.reload.short_name
    assert_equal 'SG Kaufering / Geiselbullach', team.reload.short_name
  end

  test 'ein zweiter Lauf findet nichts mehr' do
    club = club_mit('Floorball Butzbach')

    run_task('DRY_RUN' => 'false')
    out, = run_task('DRY_RUN' => 'false')

    assert_equal 'Floo', club.reload.short_name
    assert_match(/Vereine gekuerzt:\s+0/, out)
  end
end
