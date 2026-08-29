require 'test_helper'
require 'rake'

# Tests fuer player_stats:refresh (lib/tasks/player_stats.rake), den naechtlichen
# Lauf hinter der Spielerdaten-Rangliste. Was gerechnet wird, prueft
# PlayerStats::RefresherTest; hier geht es um den Task selbst: Schalter, Ausgabe und
# die Zusicherung, dass ein Probelauf nichts schreibt.
class PlayerStatsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')

    go = create(:game_operation)
    @club = create(:club, game_operation: go)
    @league = create(:league, game_operation: go, season_id: '18')
    team = create(:team, league: @league, club: @club)
    @player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    create(:game, game_day: create(:game_day, league: @league), home_team: team,
                  guest_team: create(:team, league: @league), ended: true,
                  players: { 'home' => [{ 'trikot_number' => 7, 'player_id' => @player.id }], 'guest' => [] },
                  events: [{ 'home_number' => 7, 'home_goals' => 1, 'guest_goals' => 0 }])
  end

  test 'schreibt Aggregat und Schnappschuss und nennt die Zahlen' do
    ausgabe, = run_task

    assert_equal 1, PlayerGameStat.count
    assert_equal @club.id, PlayerStatProfile.find(@player.id).home_club_id
    assert_match(/Zeilen:\s+1/, ausgabe)
    assert_match(/Profile:\s+\d+/, ausgabe)
  end

  test 'DRY_RUN rechnet, schreibt aber nicht' do
    ausgabe, = run_task(dry_run: true)

    assert_equal 0, PlayerGameStat.count
    assert_equal 0, PlayerStatProfile.count
    assert_match(/DRY RUN/, ausgabe)
  end

  # DRY_RUN=false ist die Schreibweise, die jemand fuer einen echten Lauf tippt.
  # Mit ENV['DRY_RUN'].present? waere genau das ein Probelauf gewesen.
  test 'DRY_RUN=false schreibt' do
    with_env('DRY_RUN' => 'false') { run_task(set_dry_run: false) }

    assert_equal 1, PlayerGameStat.count
  end

  test 'SEASON_ID rechnet nur diese Saison und laesst den Schnappschuss unberuehrt' do
    with_env('SEASON_ID' => '17') { run_task(set_dry_run: true) }

    assert_equal 0, PlayerGameStat.count
    assert_equal 0, PlayerStatProfile.count
  end

  private

  def run_task(dry_run: false, set_dry_run: true)
    task = Rake::Task['player_stats:refresh']
    task.reenable
    if set_dry_run
      with_env('DRY_RUN' => dry_run ? '1' : nil) { capture_io { task.invoke } }
    else
      capture_io { task.invoke }
    end
  end

  def with_env(values)
    saved = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
