require 'test_helper'
require 'rake'

# Tests für cleanup:guest_game_operations (lib/tasks/cleanup_legacy_guest_game_operations.rake).
#
# Gast-Einträge im clubs.game_operations_hash stammen ausschließlich aus dem
# Altdaten-Import 2010–2014 und wurden nie nachgeführt. Das Konzept ist
# entfallen, der Task entfernt sie deshalb ausnahmslos. Heim-Einträge bleiben
# unangetastet.
class CleanupGuestGameOperationsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['cleanup:guest_game_operations']
    @task.reenable

    create(:setting, current_season_id: '18')
    @heim_sa = create(:state_association)
    @heim_go = create(:game_operation, state_association_id: @heim_sa.id)
    @gast_go = create(:game_operation)
  end

  def run_task(env = {})
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    @task.invoke
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def club_with_guest_entry(state_association_id: nil)
    create(:club, state_association_id: state_association_id || @heim_sa.id, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => @heim_go.id },
      { 'home_game_operation' => false, 'game_operation_id' => @gast_go.id }
    ])
  end

  # `Club#additional_game_operation_ids` ist mit dem Konzept entfallen.
  def guest_ids(club)
    club.game_operations_hash.reject { |h| h['home_game_operation'] }.map { |h| h['game_operation_id'].to_i }
  end

  # Der Report-Task darf auch dann durchlaufen, wenn nichts zu bereinigen ist –
  # ein `return` im Rake-Block wirft dort LocalJumpError. Das fiel erst nach dem
  # ersten erfolgreichen Bereinigungslauf auf Produktion auf.
  test 'Report laeuft auch ohne bereinigbare Eintraege durch' do
    report = Rake::Task['cleanup:guest_game_operations_report']
    report.reenable
    create(:club, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => @heim_go.id }
    ])

    assert_nothing_raised { report.invoke }
  end

  # Gegenprobe: mit bereinigbaren Eintraegen laeuft er ebenfalls durch.
  test 'Report laeuft mit bereinigbaren Eintraegen durch' do
    report = Rake::Task['cleanup:guest_game_operations_report']
    report.reenable
    club_with_guest_entry

    assert_nothing_raised { report.invoke }
  end

  test 'Gast-Eintrag wird entfernt, Heim-Eintrag bleibt' do
    club = club_with_guest_entry

    run_task('DRY_RUN' => 'false')

    hash = club.reload.game_operations_hash
    assert_equal 1, hash.size
    assert_equal @heim_go.id, hash.first['game_operation_id']
    assert hash.first['home_game_operation']
    assert_equal @heim_go.id, club.main_game_operation_id
  end

  test 'DRY RUN ist der Default und aendert nichts' do
    club = club_with_guest_entry

    run_task

    assert_equal 2, club.reload.game_operations_hash.size
  end

  # Bis zum Wegfall des Konzepts blieb ein durch eine Liga gedeckter Eintrag
  # stehen. Das ist gewollt vorbei: Die Zustaendigkeit fuer Gastmannschaften
  # kommt aus der Liga selbst, nicht aus dem Hash.
  test 'Gast-Eintrag mit Mannschaft in einer Liga des Spielbetriebs wird ebenfalls entfernt' do
    club = club_with_guest_entry
    create(:team, club: club, league: create(:league, :current_season, game_operation: @gast_go))

    run_task('DRY_RUN' => 'false')

    assert_empty guest_ids(club.reload)
  end

  # Ebenso die frueher durch eine Vereins-Freigabe gedeckten Eintraege: Die
  # Freigabe wirkt weiter, sie braucht den Hash-Eintrag aber nicht.
  test 'Gast-Eintrag mit Vereins-Freigabe wird ebenfalls entfernt' do
    club = club_with_guest_entry
    StateAssociationRelease.create!(grantor_state_association_id: @heim_sa.id,
                                    recipient_game_operation_id: @gast_go.id,
                                    season_id: Setting.current_season_id)

    run_task('DRY_RUN' => 'false')

    assert_empty guest_ids(club.reload)
    assert club.readable_by_game_operations?([@gast_go.id]),
           'Die Freigabe muss den Lesezugriff auch ohne Gast-Eintrag tragen'
  end

  # In Altdaten liegt das Flag als String. `'false'` ist in Ruby truthy, eine
  # Truthy-Pruefung hielte den Eintrag also fuer den Heimat-Eintrag; ein
  # jsonb-`@>`-Filter auf echtes `false` faende den Verein gar nicht erst.
  # Derselbe Boolean-Cast wie in Club#main_game_operation_id loest beides.
  test 'Gast-Eintrag mit Text-Flag wird ebenfalls entfernt' do
    club = create(:club, state_association_id: @heim_sa.id, game_operations_hash: [
      { 'home_game_operation' => 'true', 'game_operation_id' => @heim_go.id },
      { 'home_game_operation' => 'false', 'game_operation_id' => @gast_go.id }
    ])

    run_task('DRY_RUN' => 'false')

    # Nicht ueber guest_ids: Dessen Truthy-Pruefung wuerde den Text-Eintrag
    # selbst uebersehen und der Test ginge auch ungefixt durch.
    assert_equal 1, club.reload.game_operations_hash.size
    assert_equal @heim_go.id, club.main_game_operation_id
  end

  test 'Verein ohne Gast-Eintrag bleibt unberuehrt' do
    club = create(:club, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => @heim_go.id }
    ])

    run_task('DRY_RUN' => 'false')

    assert_equal 1, club.reload.game_operations_hash.size
  end

  # Sicherheitsnetz: Ein Verein, dessen Hash danach ohne Heim-Eintrag
  # zurueckbliebe, wird uebersprungen statt beschaedigt.
  test 'Verein ohne Heim-Eintrag wird uebersprungen' do
    club = create(:club, game_operations_hash: [
      { 'home_game_operation' => false, 'game_operation_id' => @gast_go.id }
    ])

    run_task('DRY_RUN' => 'false')

    assert_equal 1, club.reload.game_operations_hash.size,
                 'Hash darf nicht geleert werden, wenn kein Heim-Eintrag existiert'
  end

  test 'mehrere Gast-Eintraege werden gemeinsam entfernt' do
    dritter_go = create(:game_operation)
    club = create(:club, state_association_id: @heim_sa.id, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => @heim_go.id },
      { 'home_game_operation' => false, 'game_operation_id' => @gast_go.id },
      { 'home_game_operation' => false, 'game_operation_id' => dritter_go.id }
    ])
    create(:team, club: club, league: create(:league, :current_season, game_operation: dritter_go))

    run_task('DRY_RUN' => 'false')

    assert_empty guest_ids(club.reload)
  end
end
