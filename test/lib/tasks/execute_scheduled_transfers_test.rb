require 'test_helper'
require 'rake'
require_relative '../../controllers/admin/transfer_request_test_helpers'

# Tests fuer lib/tasks/execute_scheduled_transfers.rake: Geplante Transfers
# werden am Wunschdatum vollzogen, gesperrte Vorgaenge bleiben stehen.
class ExecuteScheduledTransfersTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include Admin::TransferRequestTestHelpers

  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['transfers:execute_scheduled']
    setup_transfer_request_world
  end

  def run_task(env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }.first
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def scheduled(effective_date)
    tr = create_transfer_request(status: 'scheduled', effective_date:)
    tr.update!(approved_by_lv_user_id: @sbk.id, lv_approved_at: 1.day.ago)
    tr
  end

  def home_club_id
    @player.reload.clubs.find { |c| c['home_club'] == true && c['valid_until'].nil? }&.dig('club_id')
  end

  def berlin_today
    Time.find_zone!('Europe/Berlin').today
  end

  test 'faelliger Transfer wird vollzogen und die Vollzugsmails gehen raus' do
    tr = scheduled(berlin_today)

    # Direkt an deliveries gemessen und nicht mit assert_emails, das
    # eingereihte Jobs selbst ausfuehrt: Die Mails muessen waehrend des Laufs
    # zugestellt sein, im Cron-Prozess ginge ein :async-Job beim Prozessende
    # verloren.
    before = ActionMailer::Base.deliveries.size
    output = run_task
    assert_match(/1 geplante\(r\) Transfer\(s\) vollzogen/, output)
    assert_equal before + 2, ActionMailer::Base.deliveries.size

    assert_equal 'approved', tr.reload.status
    assert_equal @requesting_club.id, home_club_id
  end

  test 'Transfer mit Wunschdatum in der Zukunft bleibt geplant' do
    tr = scheduled(berlin_today + 1)
    assert_no_emails { run_task }
    assert_equal 'scheduled', tr.reload.status
    assert_equal @former_club.id, home_club_id
  end

  test 'ueberfaelliger Transfer wird nachgeholt' do
    tr = scheduled(berlin_today - 3)
    run_task
    assert_equal 'approved', tr.reload.status
  end

  test 'DRY_RUN vollzieht nichts' do
    tr = scheduled(berlin_today)
    output = nil
    assert_no_emails { output = run_task('DRY_RUN' => '1') }
    assert_match(/\[DRY RUN\]/, output)
    assert_equal 'scheduled', tr.reload.status
    assert_equal @former_club.id, home_club_id
  end

  test 'deaktivierter aufnehmender Verein: uebersprungen, bleibt geplant' do
    tr = scheduled(berlin_today)
    @requesting_club.update!(deactivated_at: Time.current)

    output = run_task
    assert_match(/UEBERSPRUNGEN.*deaktiviert/, output)
    assert_equal 'scheduled', tr.reload.status
    assert_equal @former_club.id, home_club_id
  end

  test 'zusammengefuehrtes Profil: uebersprungen, bleibt geplant' do
    tr = scheduled(berlin_today)
    master = create(:player, first_name: 'Max', last_name: 'Mustermann', birthdate: '1995-03-16')
    @player.update_column(:merged_into_id, master.id)

    output = run_task
    assert_match(/UEBERSPRUNGEN.*zusammengefuehrt/, output)
    assert_equal 'scheduled', tr.reload.status
  end

  test 'Fehler bei einem Vorgang haelt die uebrigen nicht auf' do
    kaputt = scheduled(berlin_today)
    kaputt.update_column(:status, 'approved') # zwischen Abfrage und Vollzug erledigt
    other = Player.create!(first_name: 'Erika', last_name: 'Muster', birthdate: '1996-01-01', nation_id: '1',
                           gender: 'f', clubs: [{ 'club_id' => @former_club.id, 'home_club' => true, 'valid_until' => nil }],
                           licenses: [])
    ok = TransferRequest.create!(player: other, requesting_club: @requesting_club, former_club: @former_club,
                                 status: 'scheduled', created_by: @sbk.id, approved_by_lv_user_id: @sbk.id,
                                 season_id: 18, effective_date: berlin_today)
    output = TransferRequest.stub(:due_for_execution, TransferRequest.where(id: [kaputt.id, ok.id])) do
      run_task
    end
    assert_match(/FEHLER Transfer ##{kaputt.id}/, output)
    assert_match(/1 fehlgeschlagen/, output)
    assert_equal 'approved', ok.reload.status
  end

  test 'setzt den Queue-Adapter nach dem Lauf zurueck' do
    before = ActiveJob::Base.queue_adapter
    scheduled(berlin_today)
    run_task
    assert_equal before, ActiveJob::Base.queue_adapter
  end
end
