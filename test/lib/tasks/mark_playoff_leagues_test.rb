require 'test_helper'
require 'rake'

# Tests fuer leagues:mark_playoffs und leagues:unmark_playoffs
# (lib/tasks/mark_playoff_leagues.rake).
#
# Der Lauf stellt Playoff- und Playdown-Ligen im Bestand von `cup` auf
# `playoff` um. Solange sie `cup` tragen, gehoeren sie zur Wettbewerbsgruppe
# `pokal`, und eine Sperre im Ligaspielbetrieb gilt in den Playoffs nicht --
# obwohl die Playoffs die Fortsetzung derselben Liga sind.
#
# Geprueft wird vor allem, was der Lauf NICHT anfasst: Ein Datenlauf, der zu
# viel umstellt, macht aus einem echten Pokal einen Teil des Ligaspielbetriebs
# und zieht damit Sperren in einen Wettbewerb, in dem sie nicht gelten sollen.
class MarkPlayoffLeaguesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    create(:setting, current_season_id: '18')
    @go = create(:game_operation)
  end

  def run_task(name, dry_run: false, env: {})
    task = Rake::Task[name]
    saved = ENV.to_hash.slice('DRY_RUN', 'SEASON', 'IDS')
    ENV['DRY_RUN'] = dry_run ? 'true' : 'false'
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }.first
  ensure
    %w[DRY_RUN SEASON IDS].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  def cup_league(name, **attrs)
    create(:league, :current_season, game_operation: @go, league_modus: 'cup', name:, **attrs)
  end

  test 'stellt eine Liga um, die Ziel einer Playoff-Qualifikation ist' do
    hauptrunde = create(:league, :current_season, game_operation: @go, league_modus: 'league')
    # Der Name sagt nichts, die gepflegte Beziehung schon.
    liga = cup_league('Endrunde Nord')
    LeagueQualification.create!(source_league: hauptrunde, target_league: liga,
                                rank_from: 1, rank_to: 4, qualification_type: 'playoff')

    run_task('leagues:mark_playoffs')

    assert_equal 'playoff', liga.reload.league_modus
  end

  test 'stellt eine Liga mit Vorrunde um' do
    hauptrunde = create(:league, :current_season, game_operation: @go, league_modus: 'league')
    liga = cup_league('Finalrunde', league_id_preround: hauptrunde.id)

    run_task('leagues:mark_playoffs')

    assert_equal 'playoff', liga.reload.league_modus
  end

  test 'stellt eine Liga nach ihrem Namen um' do
    %w[Playoffs Play-offs Playdown Meisterrunde Abstiegsrunde Platzierungsrunde Relegation].each do |wort|
      liga = cup_league("1. Bundesliga Herren #{wort}")

      run_task('leagues:mark_playoffs')

      assert_equal 'playoff', liga.reload.league_modus, wort
    end
  end

  # Der teuerste Fehler waere hier der falsch positive: Ein Pokal, der zum
  # Ligaspielbetrieb erklaert wird, faengt Sperren ein, die dort nicht gelten.
  test 'laesst einen Pokal in Ruhe, auch mit Vorrunde' do
    vorrunde = create(:league, :current_season, game_operation: @go, league_modus: 'cup')
    pokal = cup_league('FD-Pokal Endrunde', league_id_preround: vorrunde.id)
    cup = cup_league('Floorball Deutschland Cup')
    trophy = cup_league('Trophy Herren')

    run_task('leagues:mark_playoffs')

    modi = [pokal, cup, trophy].map { |l| l.reload.league_modus }

    assert_equal %w[cup cup cup], modi
  end

  # Und die Gegenprobe zur Namenssperre: Eine gepflegte Qualifikation wiegt
  # schwerer als die Benennung.
  test 'die Qualifikation schlaegt den Pokal im Namen' do
    hauptrunde = create(:league, :current_season, game_operation: @go, league_modus: 'league')
    liga = cup_league('Pokal-Playoff')
    LeagueQualification.create!(source_league: hauptrunde, target_league: liga,
                                rank_from: 1, rank_to: 2, qualification_type: 'playdown')

    run_task('leagues:mark_playoffs')

    assert_equal 'playoff', liga.reload.league_modus
  end

  test 'ohne Merkmal bleibt die Liga unangetastet und wird gemeldet' do
    liga = cup_league('Turnier der Regionen')

    ausgabe = run_task('leagues:mark_playoffs')

    assert_equal 'cup', liga.reload.league_modus
    assert_includes ausgabe, 'KEIN MERKMAL'
    assert_includes ausgabe, 'Turnier der Regionen'
  end

  test 'fasst nur cup-Ligen an' do
    liga = create(:league, :current_season, game_operation: @go, league_modus: 'league', name: 'Playoffs Nord')
    champ = create(:league, :current_season, game_operation: @go, league_modus: 'champ', name: 'DM Playoffs')

    run_task('leagues:mark_playoffs')

    assert_equal 'league', liga.reload.league_modus
    assert_equal 'champ', champ.reload.league_modus
  end

  test 'der Dry-Run aendert nichts und nennt den Weg zum Ausfuehren' do
    liga = cup_league('Playoffs Nord')

    ausgabe = run_task('leagues:mark_playoffs', dry_run: true)

    assert_equal 'cup', liga.reload.league_modus
    assert_includes ausgabe, 'DRY RUN'
    assert_includes ausgabe, 'DRY_RUN=false'
  end

  test 'SEASON grenzt den Lauf auf einzelne Saisons ein' do
    aktuell = cup_league('Playoffs Nord')
    alt = create(:league, :previous_season, game_operation: @go, league_modus: 'cup', name: 'Playoffs Nord')

    run_task('leagues:mark_playoffs', env: { 'SEASON' => '18' })

    assert_equal 'playoff', aktuell.reload.league_modus
    assert_equal 'cup', alt.reload.league_modus, 'die abgelaufene Saison war nicht gefragt'
  end

  test 'die Ausgabe nennt den Rueckweg mit den umgestellten ids' do
    liga = cup_league('Playoffs Nord')

    ausgabe = run_task('leagues:mark_playoffs')

    assert_includes ausgabe, "unmark_playoffs IDS=#{liga.id}"
  end

  test 'unmark_playoffs setzt genannte Ligen zurueck' do
    liga = cup_league('Playoffs Nord')
    run_task('leagues:mark_playoffs')

    run_task('leagues:unmark_playoffs', env: { 'IDS' => liga.id.to_s })

    assert_equal 'cup', liga.reload.league_modus
  end

  # Eine Liga, die inzwischen von Hand eingestellt wurde, gehoert nicht
  # ueberschrieben -- der Rueckweg ist fuer den Fehlgriff des Laufs da, nicht
  # fuer eine Entscheidung, die jemand danach getroffen hat.
  test 'unmark_playoffs fasst nur Ligen an, die playoff tragen' do
    liga = create(:league, :current_season, game_operation: @go, league_modus: 'league', name: 'Playoffs Nord')

    run_task('leagues:unmark_playoffs', env: { 'IDS' => liga.id.to_s })

    assert_equal 'league', liga.reload.league_modus
  end

  test 'unmark_playoffs ohne IDS tut nichts' do
    liga = cup_league('Playoffs Nord')
    run_task('leagues:mark_playoffs')

    ausgabe = run_task('leagues:unmark_playoffs')

    assert_equal 'playoff', liga.reload.league_modus
    assert_includes ausgabe, 'IDS fehlt'
  end

  # Der fachliche Grund fuer den ganzen Lauf: Nach der Umstellung greift eine
  # Sperre im Ligaspielbetrieb auch in den Playoffs.
  test 'nach der Umstellung greift die Ligasperre in den Playoffs' do
    hauptrunde = create(:league, :current_season, game_operation: @go, league_modus: 'league',
                                                  age_group: 'Herren', field_size: 'GF')
    playoffs = cup_league('1. Bundesliga Herren Playoffs', age_group: 'Herren', field_size: 'GF')
    spieler = create(:player)
    sperre = spieler.suspend!(user_id: create(:user, :admin).id, valid_until: Date.current + 30,
                              scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: hauptrunde })

    assert_not sperre.covers_league?(playoffs), 'vorher zaehlen die Playoffs als Pokal'

    run_task('leagues:mark_playoffs')

    assert sperre.covers_league?(playoffs.reload)
  end
end
