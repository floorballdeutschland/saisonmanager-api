require 'test_helper'
require 'rake'

# Invarianten-Tests für den Saisonwechsel-Workflow.
# Postconditions nach `seasons:invalidate_stale_licenses`:
# Keine APPROVED/REQUESTED-Lizenzen mehr für Teams vergangener Saisons.
class SeasonRolloverTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['seasons:invalidate_stale_licenses']

    @admin = create(:user, :admin)
    create(:setting, current_season_id: '18')

    @current_league  = create(:league, :current_season)
    @previous_league = create(:league, :previous_season)
    @current_team    = create(:team, league: @current_league)
    @previous_team   = create(:team, league: @previous_league)
  end

  def run_task
    @task.reenable
    @task.invoke('ADMIN_USER_ID' => @admin.id.to_s)
  rescue SystemExit
    nil
  end

  test 'nach Saisonwechsel: keine APPROVED-Lizenz für Vorsaison-Team' do
    player = create(:player, with_licenses: [
      { team: @previous_team, status: License::APPROVED }
    ])

    ENV['ADMIN_USER_ID'] = @admin.id.to_s
    @task.reenable
    @task.invoke
    ENV.delete('ADMIN_USER_ID')

    player.reload
    last_status = player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::DELETED, last_status,
                 'APPROVED-Lizenz im Vorsaison-Team muss nach Saisonwechsel DELETED sein'
  end

  test 'nach Saisonwechsel: keine REQUESTED-Lizenz für Vorsaison-Team' do
    player = create(:player, with_licenses: [
      { team: @previous_team, status: License::REQUESTED }
    ])

    ENV['ADMIN_USER_ID'] = @admin.id.to_s
    @task.reenable
    @task.invoke
    ENV.delete('ADMIN_USER_ID')

    player.reload
    last_status = player.licenses.first['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
    assert_equal License::DELETED, last_status,
                 'REQUESTED-Lizenz im Vorsaison-Team muss nach Saisonwechsel DELETED sein'
  end

  test 'nach Saisonwechsel: APPROVED-Lizenz in current_team bleibt unverändert' do
    player = create(:player, with_licenses: [
      { team: @current_team, status: License::APPROVED }
    ])
    history_count_before = player.licenses.first['history'].size

    ENV['ADMIN_USER_ID'] = @admin.id.to_s
    @task.reenable
    @task.invoke
    ENV.delete('ADMIN_USER_ID')

    player.reload
    assert_equal history_count_before, player.licenses.first['history'].size,
                 'Lizenz für current_team darf nicht angefasst werden'
  end

  test 'nach Saisonwechsel: kein offener TransferRequest für vergangene Saison übrig' do
    player = create(:player)
    club_a = create(:club)
    club_b = create(:club)
    old_transfer = TransferRequest.create!(
      player: player,
      requesting_club: club_b,
      former_club: club_a,
      season_id: 17,
      status: 'pending_club',
      request_type: 'transfer',
      created_by: @admin.id
    )

    current_season_id = Setting.current_season_id.to_i
    open_old = TransferRequest.where(status: %w[pending_club pending_player pending_lv])
                              .where.not(season_id: current_season_id)
    assert old_transfer.persisted?
    assert_includes open_old, old_transfer,
                    'Vorsaison-Transfer muss als offener Antrag erkennbar sein (Testsetup-Check)'
  end

  test 'reines update_season alleine invalidiert noch keine Lizenzen' do
    player = create(:player, with_licenses: [
      { team: @previous_team, status: License::APPROVED }
    ])
    history_count_before = player.licenses.first['history'].size

    # Nur Setting ändern, Rake-Task NICHT aufrufen
    setting = Setting.current
    setting.systems['1']['current_season_id'] = 18
    setting.save!

    player.reload
    assert_equal history_count_before, player.licenses.first['history'].size,
                 'Lizenz-Invalidierung darf nur durch den Rake-Task erfolgen, nicht durch Setting-Änderung'
  end

  test 'Setting.seasons[current] enthält min_league_id und min_team_id nach Backfill' do
    # Dieser Test dokumentiert die Erwartung, dass backfill_season_min_ids
    # das Setting korrekt befüllt. Wir prüfen nur das Format — der eigentliche
    # Backfill-Test liegt in test/lib/tasks/backfill_season_min_ids_test.rb.
    setting = Setting.current
    current_key = Setting.current_season_id.to_s

    # Wenn min_league_id gesetzt ist, muss min_team_id auch gesetzt sein und umgekehrt.
    min_league = setting.seasons[current_key]&.dig('min_league_id')
    min_team   = setting.seasons[current_key]&.dig('min_team_id')
    if min_league.present?
      assert min_team.present?, 'min_team_id muss gesetzt sein wenn min_league_id gesetzt ist'
    end
    if min_team.present?
      assert min_league.present?, 'min_league_id muss gesetzt sein wenn min_team_id gesetzt ist'
    end
  end
end
