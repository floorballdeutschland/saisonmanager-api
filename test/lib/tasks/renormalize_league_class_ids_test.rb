require 'test_helper'
require 'rake'

# Tests für lib/tasks/renormalize_league_class_ids.rake (#119): Der Task muss
# Ligen UND die Lizenz-Kopien in players.licenses in einem Lauf normalisieren
# (volles #297-Verhalten), idempotent sein und im Dry-Run (Standard) nichts
# schreiben. Legacy-Werte werden per update_columns gesetzt, weil die
# League-Validierung sie (gewollt) nicht mehr zulässt — genau so entstehen
# sie auch in echt (Import via update_columns/Raw-SQL).
class RenormalizeLeagueClassIdsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['leagues:renormalize_class_ids']
    @task.reenable

    create(:setting, current_season_id: '18')

    # Legacy-Wert '280' ist gemischt belegt: Namensmuster gewinnt (DM → ''),
    # sonst Wert-Mapping (→ 'rl').
    @legacy_league = create(:league, name: 'U15 Regionalliga Ost')
    @legacy_league.update_columns(league_class_id: '280')
    @dm_league = create(:league, name: 'Deutsche Meisterschaft U15')
    @dm_league.update_columns(league_class_id: '280')
    @clean_league = create(:league, name: 'Saubere Liga', league_class_id: '1fbl')

    @legacy_team = create(:team, league: @legacy_league)
    @clean_team = create(:team, league: @clean_league)
  end

  def run_task(env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    @task.invoke
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  test 'Dry-Run (Standard) ändert weder Ligen noch Lizenzen' do
    player = create(:player, with_licenses: [
                      { team: @legacy_team, league_class_id: '280' }
                    ])

    run_task

    assert_equal '280', @legacy_league.reload.league_class_id
    assert_equal '280', player.reload.licenses.first['league_class_id']
  end

  test 'Ligen: Namensmuster gewinnt vor Wert-Mapping, kanonische bleiben' do
    run_task('DRY_RUN' => 'false')

    assert_equal 'rl', @legacy_league.reload.league_class_id
    assert_equal '', @dm_league.reload.league_class_id
    assert_equal '1fbl', @clean_league.reload.league_class_id
  end

  test 'Lizenz-Kopien folgen der (normalisierten) Liga ihres Teams' do
    player = create(:player, with_licenses: [
                      { team: @legacy_team, league_class_id: '280' }
                    ])

    run_task('DRY_RUN' => 'false')

    assert_equal 'rl', player.reload.licenses.first['league_class_id']
  end

  test 'Lizenz ohne auflösbares Team fällt auf das Wert-Mapping zurück' do
    player = create(:player, with_licenses: [
                      { team: @legacy_team, league_class_id: '280' }
                    ])
    licenses = player.licenses
    licenses.first['team_id'] = 999_999
    player.update_columns(licenses:)

    run_task('DRY_RUN' => 'false')

    assert_equal 'rl', player.reload.licenses.first['league_class_id']
  end

  test 'kanonische und leere Lizenz-Werte bleiben unangetastet' do
    player = create(:player, with_licenses: [
                      { team: @clean_team, league_class_id: '2fbl' },
                      { team: @legacy_team, league_class_id: '' }
                    ])

    run_task('DRY_RUN' => 'false')

    player.reload
    assert_equal '2fbl', player.licenses.first['league_class_id']
    assert_equal '', player.licenses.last['league_class_id']
  end

  test 'Idempotenz: zweiter Lauf ändert nichts mehr' do
    player = create(:player, with_licenses: [
                      { team: @legacy_team, league_class_id: '280' }
                    ])

    run_task('DRY_RUN' => 'false')
    first_leagues = League.unscoped.pluck(:id, :league_class_id).sort
    first_licenses = player.reload.licenses

    run_task('DRY_RUN' => 'false')

    assert_equal first_leagues, League.unscoped.pluck(:id, :league_class_id).sort
    assert_equal first_licenses, player.reload.licenses
  end
end
