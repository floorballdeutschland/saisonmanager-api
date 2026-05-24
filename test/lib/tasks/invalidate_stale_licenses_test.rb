require 'test_helper'
require 'rake'

# Tests für lib/tasks/invalidate_stale_licenses.rake. Diese Rake-Task ist die
# strukturelle Antwort auf den Bonner-Vorfall (Saisonwechsel → Vorsaison-
# Lizenzen blieben aktiv). Tests decken den Happy Path, Idempotenz,
# DRY_RUN-Pfad und Edge-Cases (kein User, gelöschtes Team) ab.
class InvalidateStaleLicensesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['seasons:invalidate_stale_licenses']
    @task.reenable

    @admin = create(:user, :admin)
    create(:setting, current_season_id: '18')

    @current_league  = create(:league, :current_season)
    @previous_league = create(:league, :previous_season)
    @current_team    = create(:team, league: @current_league)
    @previous_team   = create(:team, league: @previous_league)
  end

  def run_task(env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    @task.invoke
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  test 'ohne ADMIN_USER_ID: aborted' do
    assert_raises(SystemExit) { run_task('DRY_RUN' => '1') }
  end

  test 'mit unbekannter ADMIN_USER_ID: aborted' do
    assert_raises(SystemExit) { run_task('ADMIN_USER_ID' => '999999', 'DRY_RUN' => '1') }
  end

  test 'aktive Lizenz im Vorsaison-Team wird DELETED markiert' do
    player = create(:player, with_licenses: [
      { team: @previous_team, status: License::APPROVED }
    ])

    run_task('ADMIN_USER_ID' => @admin.id.to_s)

    player.reload
    history = player.licenses.first['history']
    assert_equal 2, history.size, 'Original-Eintrag + DELETED-Markierung'
    last = history.last
    assert_equal License::DELETED, last['license_status_id']
    assert_equal 'Saisonwechsel — Lizenz aus Vorsaison', last['reason']
    assert_equal @admin.id, last['created_by']
    refute_nil last['created_at']
  end

  test 'aktive Lizenz im current_team bleibt unverändert' do
    player = create(:player, with_licenses: [
      { team: @current_team, status: License::APPROVED }
    ])
    history_before = player.licenses.first['history'].dup

    run_task('ADMIN_USER_ID' => @admin.id.to_s)

    player.reload
    assert_equal history_before.size, player.licenses.first['history'].size
  end

  test 'bereits DELETED-Lizenz bleibt unverändert (Idempotenz)' do
    player = create(:player, with_licenses: [
      { team: @previous_team, status: License::DELETED }
    ])
    history_before = player.licenses.first['history'].dup

    run_task('ADMIN_USER_ID' => @admin.id.to_s)

    player.reload
    assert_equal history_before.size, player.licenses.first['history'].size
  end

  test 'doppelter Lauf erzeugt keinen weiteren DELETED-Eintrag' do
    player = create(:player, with_licenses: [
      { team: @previous_team, status: License::APPROVED }
    ])

    run_task('ADMIN_USER_ID' => @admin.id.to_s)
    player.reload
    size_after_first = player.licenses.first['history'].size

    run_task('ADMIN_USER_ID' => @admin.id.to_s)
    player.reload
    assert_equal size_after_first, player.licenses.first['history'].size,
                 'Zweiter Lauf darf nichts mehr ändern'
  end

  test 'Lizenz auf gelöschtem Team wird übersprungen (skipped_team_missing)' do
    deleted_team_id = 999_999  # existiert nicht
    player = Player.new(first_name: 'Skip', last_name: 'Test',
                        birthdate: '1990-01-01', nation_id: '1',
                        licenses: [
                          { 'team_id' => deleted_team_id,
                            'history' => [{ 'license_status_id' => License::APPROVED,
                                            'created_at' => Time.current.iso8601 }] }
                        ])
    player.save!(validate: false)
    history_before = player.licenses.first['history'].dup

    run_task('ADMIN_USER_ID' => @admin.id.to_s)

    player.reload
    assert_equal history_before.size, player.licenses.first['history'].size
  end

  test 'DRY_RUN ändert nichts in der DB' do
    player = create(:player, with_licenses: [
      { team: @previous_team, status: License::APPROVED }
    ])
    history_before = player.licenses.first['history'].dup

    run_task('ADMIN_USER_ID' => @admin.id.to_s, 'DRY_RUN' => '1')

    player.reload
    assert_equal history_before.size, player.licenses.first['history'].size,
                 'DRY_RUN darf keinen save! auslösen'
  end
end
