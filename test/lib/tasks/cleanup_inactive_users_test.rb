require 'test_helper'
require 'rake'

# Tests für cleanup:inactive_users (lib/tasks/cleanup.rake): Inaktive VM/TM-
# Konten (kein Login seit >3 Jahren) werden archiviert – nicht mehr gelöscht.
class CleanupInactiveUsersTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['cleanup:inactive_users']
    @task.reenable
  end

  def run_task(env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    @task.invoke
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  test 'inaktiver VM wird archiviert, nicht gelöscht' do
    user = create(:user, :vm, last_login_at: 4.years.ago)

    run_task

    user.reload
    assert user.archived?
    assert_nil user.archived_by
  end

  test 'ADMIN_USER_ID landet in archived_by' do
    admin = create(:user, :admin, last_login_at: 1.day.ago)
    user = create(:user, :tm, last_login_at: 4.years.ago)

    run_task('ADMIN_USER_ID' => admin.id.to_s)

    assert_equal admin.id, user.reload.archived_by
  end

  test 'nie eingeloggter Alt-Account wird über created_at erfasst' do
    user = create(:user, :vm, last_login_at: nil, created_at: 4.years.ago)

    run_task

    assert user.reload.archived?
  end

  test 'kürzlich aktiver VM bleibt unangetastet' do
    user = create(:user, :vm, last_login_at: 1.month.ago)

    run_task

    refute user.reload.archived?
  end

  test 'Konto mit geschützter Rolle (Admin/SBK/RSK/Schiri) bleibt unangetastet' do
    mixed = create(:user, last_login_at: 4.years.ago, permissions: [
      { 'user_group_id' => 4, 'club_id' => '1' },
      { 'user_group_id' => 2, 'game_operation_id' => '1' }
    ])

    run_task

    refute mixed.reload.archived?
  end

  test 'bereits archivierte Konten werden nicht erneut archiviert' do
    stamp = 2.months.ago.change(usec: 0)
    user = create(:user, :vm, last_login_at: 4.years.ago, archived_at: stamp, archived_by: 42)

    run_task

    user.reload
    assert_equal stamp, user.archived_at
    assert_equal 42, user.archived_by
  end

  test 'DRY_RUN archiviert nichts' do
    user = create(:user, :vm, last_login_at: 4.years.ago)

    run_task('DRY_RUN' => '1')

    refute user.reload.archived?
  end
end
