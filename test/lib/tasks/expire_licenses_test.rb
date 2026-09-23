require 'test_helper'
require 'rake'

# licenses:expire liest seit #725 den Basisstatus ueber LicenseEffectiveStatus.
class ExpireLicensesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['licenses:expire']
    @admin = create(:user, :admin)
    create(:setting, current_season_id: '18')
    @team = create(:team)
  end

  def run_task
    saved = ENV.fetch('ADMIN_USER_ID', nil)
    ENV['ADMIN_USER_ID'] = @admin.id.to_s
    @task.reenable
    @task.invoke
  ensure
    ENV['ADMIN_USER_ID'] = saved
  end

  def player_with(history)
    create(:player, licenses: [{ 'id' => SecureRandom.uuid, 'team_id' => @team.id,
                                 'valid_until' => '2026-01-31', 'history' => history }])
  end

  test 'abgelaufene erteilte Lizenz wird trotz Offset-Unordnung geloescht' do
    player = player_with([{ 'license_status_id' => License::APPROVED, 'created_at' => '2025-08-03T18:25:00+00:00' },
                          { 'license_status_id' => License::REQUESTED, 'created_at' => '2025-08-03T19:59:00+02:00' }])

    run_task

    assert_equal License::DELETED, License.current_status_id(player.reload.licenses.first)
  end

  test 'abgelaufene gesperrte Lizenz wird ebenfalls geloescht' do
    player = player_with([{ 'license_status_id' => License::APPROVED, 'created_at' => '2025-08-01T10:00:00+00:00' },
                          { 'license_status_id' => License::SUSPENDED, 'created_at' => '2025-09-01T10:00:00+00:00' }])

    run_task

    assert_equal License::DELETED, License.current_status_id(player.reload.licenses.first)
  end

  # Begruendet den Basisstatus: Nach dem Ablauf bleibt DELETED oben, das Ende
  # der Sperre holt die Lizenz nicht auf `erteilt` zurueck.
  test 'nach Ablauf bleibt die Lizenz auch beim Aufheben der Sperre geloescht' do
    player = player_with([{ 'license_status_id' => License::APPROVED, 'created_at' => '2025-08-01T10:00:00+00:00' }])
    suspension = player.suspend!(user_id: @admin.id, reason: 'Test', games_total: 2)

    run_task
    player.reload.lift_suspension!(suspension.reload, user_id: @admin.id)

    statuses = player.reload.licenses.first['history'].map { |h| h['license_status_id'].to_i }
    assert_equal [License::APPROVED, License::SUSPENDED, License::DELETED], statuses
  end
end
