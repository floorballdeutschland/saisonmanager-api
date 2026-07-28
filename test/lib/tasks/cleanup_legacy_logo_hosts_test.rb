require 'test_helper'
require 'rake'

# Tests für cleanup:legacy_logo_hosts (lib/tasks/fix_legacy_logo_hosts.rake):
# Absolute Logo-URLs auf den Alt-Server werden zu relativen Pfaden gekürzt,
# damit die Startseite keine Basic-Auth-Challenge des Alt-Servers mehr auslöst.
class CleanupLegacyLogoHostsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['cleanup:legacy_logo_hosts']
    @task.reenable
  end

  # Default ist Dry-Run, deshalb laufen die schreibenden Tests mit DRY_RUN=false.
  def run_task(env = { 'DRY_RUN' => 'false' })
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    @task.invoke
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  test 'Alt-Server-Host wird aus logo_url entfernt' do
    go = create(:game_operation, logo_url: 'https://api.saisonmanager.de/verband/sbkost.png')

    run_task

    assert_equal '/verband/sbkost.png', go.reload.logo_url
  end

  test 'alte Domain saisonmanager.org wird ebenfalls gekürzt' do
    go = create(:game_operation, logo_quad_url: 'http://saisonmanager.org/verband/fvbb_quad.png')

    run_task

    assert_equal '/verband/fvbb_quad.png', go.reload.logo_quad_url
  end

  test 'Rand-Whitespace wird entfernt' do
    go = create(:game_operation, logo_quad_url: "https://api.saisonmanager.de/verband/rlpsaar.png\r\n")

    run_task

    assert_equal '/verband/rlpsaar.png', go.reload.logo_quad_url
  end

  test 'relative Pfade und Fremdhosts bleiben unangetastet' do
    blob = create(:game_operation, logo_url: '/api/storage/blobs/redirect/abc/sh.webp')
    extern = create(:game_operation, logo_url: 'https://fvnb.de/wp-content/uploads/fvnb_logo.jpg')

    run_task

    assert_equal '/api/storage/blobs/redirect/abc/sh.webp', blob.reload.logo_url
    assert_equal 'https://fvnb.de/wp-content/uploads/fvnb_logo.jpg', extern.reload.logo_url
  end

  test 'DRY_RUN ändert nichts' do
    url = 'https://api.saisonmanager.de/verband/sbkost.png'
    go = create(:game_operation, logo_url: url)

    run_task('DRY_RUN' => '1')

    assert_equal url, go.reload.logo_url
  end
end
