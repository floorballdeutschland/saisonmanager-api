require 'test_helper'
require 'rake'

# Tests für players:trim_names und players:report_untrimmed_names
# (lib/tasks/trim_player_names.rake, api#496).
#
# Der Task räumt den Rand von Vor- und Nachname aus dem Bestand. Er greift damit
# an Datensätze, die Player#strip_names nie gesehen hat (Altbestand, rohe
# Importe, `update_column`), und darf dabei nichts anderes verändern als den
# Rand -- insbesondere aus einem fehlenden Namen kein leeres Feld machen.
class TrimPlayerNamesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')
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

  # update_column, weil das Speichern den Rand sonst schon vor dem Test entfernt
  # -- genau das ist der Sinn von Player#strip_names.
  def player_mit_namen(first_name, last_name)
    player = create(:player)
    player.update_columns(first_name: first_name, last_name: last_name)
    player
  end

  test 'trimmt Leerzeichen am Namensrand' do
    player = player_mit_namen(' Daniel', 'Düsentrieb ')

    run_task('players:trim_names', 'DRY_RUN' => 'false')

    player.reload
    assert_equal 'Daniel', player.first_name
    assert_equal 'Düsentrieb', player.last_name
  end

  test 'trimmt einen Tabulator am Namensende' do
    player = player_mit_namen("Daniel\t", 'Düsentrieb')

    run_task('players:trim_names', 'DRY_RUN' => 'false')

    assert_equal 'Daniel', player.reload.first_name
  end

  test 'laesst einen fehlenden Vornamen NULL, wenn nur der Nachname Rand traegt' do
    player = player_mit_namen(nil, 'Düsentrieb ')

    run_task('players:trim_names', 'DRY_RUN' => 'false')

    player.reload
    assert_nil player.first_name
    assert_equal 'Düsentrieb', player.last_name
  end

  test 'Dry-Run schreibt nicht' do
    player = player_mit_namen('Daniel ', 'Düsentrieb')

    run_task('players:trim_names')

    assert_equal 'Daniel ', player.reload.first_name
  end

  test 'zweiter Lauf findet nichts mehr' do
    player_mit_namen('Daniel ', 'Düsentrieb')
    run_task('players:trim_names', 'DRY_RUN' => 'false')

    ausgabe, = run_task('players:report_untrimmed_names')

    assert_match(/Namensrand: 0 ==/, ausgabe)
  end

  test 'Bericht zaehlt auch tabulatorgepolsterte Namen' do
    player_mit_namen("Daniel\t", 'Düsentrieb')

    ausgabe, = run_task('players:report_untrimmed_names')

    assert_match(/Namensrand: 1 ==/, ausgabe)
  end
end
