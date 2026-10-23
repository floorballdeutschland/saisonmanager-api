require 'test_helper'
require 'rake'
require 'tempfile'

# Tests fuer lib/tasks/referees_merge_duplicates.rake: die gepruefte
# Dublettenliste aus dem Durchgang vom 23.10.2026.
class RefereesMergeDuplicatesTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    create(:setting)
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['referees:merge_duplicates']
  end

  def run_task(csv, env = {})
    file = Tempfile.new(['dubletten', '.csv'])
    file.write("ids;vorname;nachname;geburtsdatum;lizenzstufe\n#{csv}")
    file.close
    env = env.merge('FILE' => file.path)
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }.first
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
    file&.unlink
  end

  # Der Fall Noerlich: drei Profile, das juengste mit Konto und falscher Schreibweise.
  def triple
    oldest = create(:referee, lizenznummer: 8016, vorname: 'Kurt', nachname: 'Nörlich',
                              geburtsdatum: Date.new(2010, 11, 21), lizenzstufe: 'LJ', gueltigkeit: Date.new(2025, 9, 30))
    middle = create(:referee, lizenznummer: 8701, vorname: 'Kurt', nachname: 'Nörlich', email: 'mitte@example.org',
                              geburtsdatum: Date.new(2011, 11, 21), lizenzstufe: 'LJ', gueltigkeit: Date.new(2026, 7, 31))
    current = create(:referee, lizenznummer: 9052, vorname: 'Kurt', nachname: 'Noerlich', email: 'kurt@example.org',
                               geburtsdatum: Date.new(2010, 11, 21), lizenzstufe: 'J1', gueltigkeit: Date.new(2027, 9, 30))
    user = create(:user, user_name: 'sr-9052', referee_id: current.id, permissions: [{ 'user_group_id' => 6 }])
    [oldest, middle, current, user]
  end

  test 'DRY_RUN schreibt nichts und nennt Master und Nummernwechsel' do
    oldest, middle, current, = triple

    out = run_task("#{current.id} #{middle.id} #{oldest.id};;Nörlich;;", 'DRY_RUN' => '1')

    assert_includes out, "Master ##{oldest.id} (Nr. 8016)"
    assert_includes out, 'Nummer aendert sich: 9052 -> 8016'
    assert_nil current.reload.merged_into_id
    assert_equal 'Noerlich', current.nachname
  end

  test 'fuehrt die Gruppe in die kleinste Nummer zusammen, korrigiert und mailt nur einmal' do
    oldest, middle, current, user = triple

    assert_enqueued_emails 1 do
      run_task("#{current.id} #{middle.id} #{oldest.id};;Nörlich;2010-11-21;")
    end

    oldest.reload
    assert_equal [oldest.id, oldest.id], [middle.reload.merged_into_id, current.reload.merged_into_id]
    assert_equal ['Kurt', 'Nörlich', Date.new(2010, 11, 21)], [oldest.vorname, oldest.nachname, oldest.geburtsdatum]
    assert_equal ['J1', Date.new(2027, 9, 30), 'kurt@example.org'], [oldest.lizenzstufe, oldest.gueltigkeit, oldest.email]
    assert_equal [oldest.id, 'sr-8016'], [user.reload.referee_id, user.user_name]
  end

  test 'setzt eine angegebene Lizenzstufe nach dem Zusammenfuehren' do
    a = create(:referee, lizenznummer: 3569, lizenzstufe: 'L3', gueltigkeit: Date.new(2024, 9, 30))
    b = create(:referee, lizenznummer: 6277, lizenzstufe: 'L2', gueltigkeit: Date.new(2024, 9, 30))

    run_task("#{a.id} #{b.id};;;;L2")

    assert_equal a.id, b.reload.merged_into_id
    assert_equal 'L2', a.reload.lizenzstufe
  end

  test 'ueberspringt eine Gruppe mit bereits zusammengefuehrtem Profil' do
    a = create(:referee, lizenznummer: 100)
    b = create(:referee, lizenznummer: 200)
    b.merge_into!(a)

    out = run_task("#{a.id} #{b.id};;;;")

    assert_includes out, 'bereits zusammengefuehrtes Profil'
  end
end
