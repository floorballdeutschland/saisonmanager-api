require 'test_helper'
require 'rake'

# Tests für lib/tasks/backfill_season_min_ids.rake. Setzt min_league_id /
# min_team_id für Saisons, denen diese Werte fehlen. Begleitete den
# strukturellen Fix aus PR #168 (ohne diese Werte fällt
# Setting.current_min_team auf 0 → Bonner-Vorfall).
class BackfillSeasonMinIdsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['seasons:backfill_min_ids']
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

  test 'Saison mit Ligen+Teams: min_team_id und min_league_id werden gesetzt' do
    setting = create(:setting, current_season_id: 18, current_min_team: nil, current_min_league: nil)
    league = create(:league, :current_season)
    team   = create(:team, league: league)

    run_task

    setting.reload
    assert_equal league.id, setting.seasons['18']['min_league_id']
    assert_equal team.id,   setting.seasons['18']['min_team_id']
  end

  test 'Saison mit bereits gesetzten Werten bleibt unverändert' do
    setting = create(:setting, current_season_id: 18, current_min_team: 4711, current_min_league: 1234)
    create(:league, :current_season)

    run_task

    setting.reload
    assert_equal 4711, setting.seasons['18']['min_team_id']
    assert_equal 1234, setting.seasons['18']['min_league_id']
  end

  test 'Saison mit Ligen aber ohne Teams: keine Werte gesetzt (Härtung aus PR #171)' do
    setting = create(:setting, current_season_id: 18, current_min_team: nil, current_min_league: nil)
    create(:league, :current_season)
    # KEINE Teams angelegt — Härtung soll dann nichts schreiben.

    run_task

    setting.reload
    refute setting.seasons['18'].key?('min_team_id'),
           'min_team_id darf nicht aus Müllwerten geraten werden'
  end

  test 'Saison ganz ohne Ligen wird übersprungen' do
    setting = create(:setting, current_season_id: 18, current_min_team: nil, current_min_league: nil)
    # Keine League für '18' anlegen.

    run_task

    setting.reload
    refute setting.seasons['18'].key?('min_league_id')
    refute setting.seasons['18'].key?('min_team_id')
  end

  test 'DRY_RUN ändert nichts in der DB' do
    setting = create(:setting, current_season_id: 18, current_min_team: nil, current_min_league: nil)
    league = create(:league, :current_season)
    create(:team, league: league)

    run_task('DRY_RUN' => '1')

    setting.reload
    refute setting.seasons['18'].key?('min_team_id'),
           'DRY_RUN darf seasons-Spalte nicht persistieren'
  end
end
