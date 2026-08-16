require 'test_helper'
require 'rake'

# Tests für lib/tasks/cleanup_orphan_team_leagues.rake und die beiden neuen
# Prüfungen in lib/tasks/data_health.rake (#293).
#
# `teams.league_id` hat keinen Fremdschlüssel. Eine Mannschaft kann deshalb auf
# eine Liga zeigen, die es nicht mehr gibt; die Mannschaftsseite ist dann leer
# (vor #283 ein Serverfehler, seitdem ein 404). Solange niemand danach sucht,
# fällt das nicht auf.
class CleanupOrphanTeamLeaguesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')
    @club = create(:club)
    @league = create(:league)
  end

  # Die data_health-Tasks beenden bei Funden mit Exit-Code 1, so wertet der
  # Cronjob sie aus. Im Test darf das den Prozess nicht mitnehmen, deshalb wird
  # SystemExit abgefangen und als zweiter Rückgabewert gereicht.
  def run_task(name, env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task = Rake::Task[name]
    task.reenable
    status = 0
    out, = capture_io do
      task.invoke
    rescue SystemExit => e
      status = e.status
    end
    [out, status]
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  # Eine Mannschaft, deren Liga danach aus der Datenbank verschwindet. Der Weg
  # über die Anwendung nimmt die Mannschaft mit; hier wird genau der Weg
  # nachgestellt, der das nicht tut (delete_all aus Konsole oder Rake-Task).
  #
  # Der Fremdschlüssel aus derselben Änderung verhindert genau das inzwischen,
  # muss für die Prüfung des Altbestands also kurz weichen. Das DDL läuft in der
  # Testtransaktion und ist mit ihr wieder verschwunden; die Sperre selbst prüft
  # der Test weiter unten.
  def team_with_deleted_league
    weg = create(:league)
    team = create(:team, league: weg, club: @club)
    ActiveRecord::Base.connection.remove_foreign_key(:teams, :leagues)
    League.unscoped.where(id: weg.id).delete_all
    [team, weg.id]
  end

  test 'orphan_teams findet die verwaiste Mannschaft und nur sie' do
    team, weg_id = team_with_deleted_league
    create(:team, league: @league, club: @club)

    out, status = run_task('data_health:orphan_teams')

    assert_match(/1 Mannschaft\(en\)/, out)
    assert_match(/#{team.id}/, out)
    assert_match(/#{weg_id}/, out, 'die verwaiste ID gehört in die Ausgabe, sie ist der einzige Hinweis')
    assert_equal 1, status, 'ein Befund muss den Exit-Code setzen, sonst meldet sich der Cronjob nie'
  end

  # league_id IS NULL ist kein Befund: Der Fremdschlüssel ließe das ebenfalls zu,
  # und die Anwendung meldet den Fall seit #283 verständlich.
  test 'orphan_teams meldet eine Mannschaft ohne Liga nicht' do
    create(:team, league: @league, club: @club).update_columns(league_id: nil)

    out, = run_task('data_health:orphan_teams')

    assert_match(/0 Mannschaft\(en\)/, out)
  end

  # Die Datenbank lässt den Zustand ab jetzt gar nicht mehr entstehen. Das ist
  # der eigentliche Riegel; die Prüfung und der Bereinigungslauf darüber gelten
  # dem Altbestand und allen Wegen, die den Fremdschlüssel umgehen könnten.
  test 'die Datenbank verweigert das Loeschen einer Liga mit Mannschaften' do
    weg = create(:league)
    create(:team, league: weg, club: @club)

    # Savepoint: Ein Fremdschlüsselfehler reißt sonst die Testtransaktion mit,
    # und jede weitere Abfrage liefe in PG::InFailedSqlTransaction.
    assert_raises(ActiveRecord::InvalidForeignKey) do
      ActiveRecord::Base.transaction(requires_new: true) do
        League.unscoped.where(id: weg.id).delete_all
      end
    end
    assert League.unscoped.exists?(weg.id)
  end

  test 'orphan_cup_leagues findet geloeschte IDs im Pokalliga-Array' do
    weg = create(:league)
    team = create(:team, league: @league, club: @club, cup_leagues: [@league.id, weg.id])
    League.unscoped.where(id: weg.id).delete_all

    out, = run_task('data_health:orphan_cup_leagues')

    assert_match(/1 Mannschaft\(en\)/, out)
    assert_match(/#{team.id}/, out)
  end

  test 'Dry-Run schreibt nichts und nennt den Rueckweg' do
    team, weg_id = team_with_deleted_league

    out, = run_task('cleanup:orphan_team_leagues')

    assert_match(/DRY RUN/, out)
    assert_match(/ROLLBACK: Team.where\(id: #{team.id}\).update_all\(league_id: #{weg_id}\)/, out)
    assert_equal weg_id, team.reload.league_id
  end

  test 'DRY_RUN=false nullt die verwaiste league_id und laesst die Mannschaft stehen' do
    team, = team_with_deleted_league
    heil = create(:team, league: @league, club: @club)

    run_task('cleanup:orphan_team_leagues', 'DRY_RUN' => 'false')

    assert_nil team.reload.league_id
    assert Team.exists?(team.id), 'die Mannschaft trägt Kader und Historie und darf nicht verschwinden'
    assert_equal @league.id, heil.reload.league_id
  end

  test 'DRY_RUN=false entfernt nur die geloeschten IDs aus cup_leagues' do
    weg = create(:league)
    team = create(:team, league: @league, club: @club, cup_leagues: [@league.id, weg.id])
    League.unscoped.where(id: weg.id).delete_all

    run_task('cleanup:orphan_team_leagues', 'DRY_RUN' => 'false')

    assert_equal [@league.id], team.reload.cup_leagues
  end

  # Nach dem Lauf muss die Prüfung schweigen, sonst schlägt die geplante
  # Migration mit add_foreign_key weiterhin fehl.
  test 'nach dem Lauf ist der Bestand sauber' do
    team_with_deleted_league

    run_task('cleanup:orphan_team_leagues', 'DRY_RUN' => 'false')
    out, = run_task('data_health:orphan_teams')

    assert_match(/0 Mannschaft\(en\)/, out)
  end
end
