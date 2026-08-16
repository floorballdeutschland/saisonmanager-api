require 'test_helper'
require 'rake'

# `cleanup:delete_empty_leagues` und die Pokalliga-Verweise (#293).
#
# `empty_leagues` zählt nur eigene Mannschaften und Spiele. Eine Liga, auf die
# ausschließlich über die `cup_leagues` FREMDER Mannschaften verwiesen wird, hat
# beides nicht und galt damit als leer. Nach dem Löschen blieb ihre ID in den
# Arrays der anderen Mannschaften stehen.
#
# Das ist die mutmaßliche Quelle der 22 verwaisten Pokalliga-Einträge auf
# Produktion, und ein Fremdschlüssel kann sie nicht schließen: Postgres kennt
# keine Fremdschlüssel auf Array-Elemente. Deshalb prüft
# `league_reference_blockers` jetzt dasselbe, was
# `LeaguesController#league_delete_blocker` schon länger prüft.
class DeleteEmptyLeaguesCupReferenceTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')
    @club = create(:club)
    # Vorsaison, sonst greift der Schutz der aktiven Saison und der Test
    # bewiese nur den.
    @aktive_liga = create(:league, :previous_season)
  end

  def run_task(env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task = Rake::Task['cleanup:delete_empty_leagues']
    task.reenable
    out, err = capture_io { task.invoke }
    out + err
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  test 'eine nur als Pokalliga referenzierte Liga wird nicht mehr geloescht' do
    pokal = create(:league, :previous_season)
    team = create(:team, league: @aktive_liga, club: @club, cup_leagues: [pokal.id])

    out = run_task('DRY_RUN' => 'false')

    assert League.unscoped.exists?(pokal.id), 'die Liga ist noch als Pokalliga hinterlegt'
    assert_match(/ÜBERSPRUNGEN ##{pokal.id}/, out)
    assert_match(/zusätzliche Liga/, out)
    assert_equal [pokal.id], team.reload.cup_leagues
  end

  # Gegenprobe: Der neue Riegel darf den Zweck des Laufs nicht aushebeln. Eine
  # wirklich unreferenzierte leere Liga verschwindet weiterhin.
  test 'eine unreferenzierte leere Liga wird weiterhin geloescht' do
    verwaist = create(:league, :previous_season)

    run_task('DRY_RUN' => 'false')

    assert_not League.unscoped.exists?(verwaist.id)
  end

  # Die eigene Liga der Mannschaft zählt nicht als Fremdverweis, sonst blockierte
  # jede Mannschaft ihre eigene Liga über den cup_leagues-Zweig.
  test 'die eigene Liga einer Mannschaft blockiert nicht ueber den Pokal-Zweig' do
    eigene = create(:league, :previous_season)
    create(:team, league: eigene, club: @club, cup_leagues: [eigene.id])

    out = run_task('DRY_RUN' => 'false')

    # Sie hat eine eigene Mannschaft, ist also gar nicht leer und taucht nicht auf.
    assert League.unscoped.exists?(eigene.id)
    assert_no_match(/ÜBERSPRUNGEN ##{eigene.id}/, out)
  end
end
