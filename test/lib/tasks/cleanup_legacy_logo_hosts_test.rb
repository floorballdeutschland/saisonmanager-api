require 'test_helper'
require 'rake'

# Tests für cleanup:legacy_logo_hosts (lib/tasks/cleanup_legacy_logo_hosts.rake):
# Absolute Logo-URLs werden zu relativen Pfaden gekürzt, damit die Startseite
# keine Basic-Auth-Challenge des Alt-Servers mehr auslöst.
class CleanupLegacyLogoHostsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['cleanup:legacy_logo_hosts']
    @task.reenable
  end

  # Default ist Trockenlauf, deshalb laufen die schreibenden Tests mit
  # DRY_RUN=false. ENV[k] = nil löscht die Variable, damit lässt sich auch der
  # Default selbst testen.
  def run_task(env = { 'DRY_RUN' => 'false' })
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    capture_io { @task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  test 'Alt-Server-Host wird aus logo_url entfernt' do
    go = create(:game_operation, logo_url: 'https://api.saisonmanager.de/verband/sbkost.png')

    run_task

    assert_equal '/verband/sbkost.png', go.reload.logo_url
  end

  test 'beide Logo-Spalten einer Zeile werden in einem Lauf korrigiert' do
    go = create(:game_operation,
                logo_url: 'https://api.saisonmanager.de/verband/sbkost.png',
                logo_quad_url: 'https://api.saisonmanager.de/verband/sbkost_quad.png')

    run_task

    go.reload
    assert_equal '/verband/sbkost.png', go.logo_url
    assert_equal '/verband/sbkost_quad.png', go.logo_quad_url
  end

  test 'alle Host-Varianten werden gekürzt' do
    variants = ['https://saisonmanager.de/verband/x.png',
                'http://api.saisonmanager.de/verband/x.png',
                'https://api.saisonmanager.org/verband/x.png',
                'HTTPS://API.SAISONMANAGER.DE/verband/x.png']
    operations = variants.map { |url| create(:game_operation, logo_url: url) }

    run_task

    operations.each { |go| assert_equal '/verband/x.png', go.reload.logo_url }
  end

  test 'Rand-Whitespace wird auch ohne Alt-Host entfernt' do
    go = create(:game_operation, logo_quad_url: "/api/storage/blobs/redirect/abc/rlpsaar.webp\r\n")

    run_task

    assert_equal '/api/storage/blobs/redirect/abc/rlpsaar.webp', go.reload.logo_quad_url
  end

  test 'relative Pfade und Fremdhosts bleiben unangetastet' do
    blob = create(:game_operation, logo_url: '/api/storage/blobs/redirect/abc/sh.webp')
    extern = create(:game_operation, logo_url: 'https://fvnb.de/wp-content/uploads/fvnb_logo.jpg')

    run_task

    assert_equal '/api/storage/blobs/redirect/abc/sh.webp', blob.reload.logo_url
    assert_equal 'https://fvnb.de/wp-content/uploads/fvnb_logo.jpg', extern.reload.logo_url
  end

  test 'Alt-Host mitten in der URL bleibt liegen und wird gemeldet' do
    url = 'https://fvnb.de/r?to=https://api.saisonmanager.de/verband/x.png'
    go = create(:game_operation, logo_url: url)

    out, = run_task

    assert_equal url, go.reload.logo_url
    assert_match(/nicht am Anfang der URL/, out)
  end

  test 'Link-Spalten werden nicht angefasst' do
    banner = 'https://api.saisonmanager.de/sponsor.html'
    go = create(:game_operation, logo_url: 'https://api.saisonmanager.de/verband/sbkost.png',
                                 banner_link_url: banner)
    league = create(:league, banner_link_url: banner)

    run_task

    assert_equal '/verband/sbkost.png', go.reload.logo_url, 'Logo sollte korrigiert sein'
    assert_equal banner, go.banner_link_url
    assert_equal banner, league.reload.banner_link_url
  end

  test 'zweiter Lauf ist ein No-Op' do
    go = create(:game_operation, logo_url: 'https://api.saisonmanager.de/verband/sbkost.png')

    run_task
    out, = run_task

    assert_equal '/verband/sbkost.png', go.reload.logo_url
    assert_match(/0 Spielbetriebe/, out)
  end

  test 'ohne DRY_RUN-Variable wird nichts geschrieben' do
    url = 'https://api.saisonmanager.de/verband/sbkost.png'
    go = create(:game_operation, logo_url: url)

    run_task('DRY_RUN' => nil)

    assert_equal url, go.reload.logo_url
  end

  test 'jeder DRY_RUN-Wert außer false bleibt Trockenlauf' do
    url = 'https://api.saisonmanager.de/verband/sbkost.png'
    go = create(:game_operation, logo_url: url)

    run_task('DRY_RUN' => '1')

    assert_equal url, go.reload.logo_url
  end
end
