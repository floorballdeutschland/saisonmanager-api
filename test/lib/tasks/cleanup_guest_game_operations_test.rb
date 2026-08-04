require 'test_helper'
require 'rake'

# Tests für cleanup:guest_game_operations (lib/tasks/cleanup_legacy_guest_game_operations.rake).
#
# Gast-Einträge im clubs.game_operations_hash stammen ausschließlich aus dem
# Altdaten-Import 2010–2014 und werden nie nachgeführt. Der Task entfernt die,
# die weder durch eine aktuelle Liga noch durch eine Vereins-Freigabe gedeckt
# sind. Heim-Einträge bleiben unangetastet.
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

  test 'ungedeckter Gast-Eintrag wird entfernt, Heim-Eintrag bleibt' do
    club = club_with_guest_entry

    run_task('DRY_RUN' => 'false')

    hash = club.reload.game_operations_hash
    assert_equal 1, hash.size
    assert_equal @heim_go.id, hash.first['game_operation_id']
    assert hash.first['home_game_operation']
    assert_equal @heim_go.id, club.main_game_operation_id
    assert_empty club.additional_game_operation_ids
  end

  test 'DRY RUN ist der Default und aendert nichts' do
    club = club_with_guest_entry

    run_task

    assert_equal 2, club.reload.game_operations_hash.size
  end

  # Gedeckt durch eine aktuelle Liga: Der Verein spielt in diesem Spielbetrieb.
  test 'Gast-Eintrag mit Mannschaft in einer Liga des Spielbetriebs bleibt' do
    club = club_with_guest_entry
    create(:team, club: club, league: create(:league, :current_season, game_operation: @gast_go))

    run_task('DRY_RUN' => 'false')

    assert_includes club.reload.additional_game_operation_ids, @gast_go.id
  end

  # Auch als SG-Partnerverein zaehlt die Mannschaft.
  test 'Gast-Eintrag bleibt, wenn der Verein nur SG-Partner der Mannschaft ist' do
    club = club_with_guest_entry
    team = create(:team, club: create(:club), league: create(:league, :current_season, game_operation: @gast_go))
    team.update!(syndicate_clubs: [club.id])

    run_task('DRY_RUN' => 'false')

    assert_includes club.reload.additional_game_operation_ids, @gast_go.id
  end

  # Gedeckt durch eine Vereins-Freigabe des eigenen Landesverbands.
  test 'Gast-Eintrag mit Vereins-Freigabe bleibt' do
    club = club_with_guest_entry
    StateAssociationRelease.create!(grantor_state_association_id: @heim_sa.id,
                                    recipient_game_operation_id: @gast_go.id,
                                    season_id: Setting.current_season_id)

    run_task('DRY_RUN' => 'false')

    assert_includes club.reload.additional_game_operation_ids, @gast_go.id
  end

  # Eine Mannschaft der VORSAISON deckt nichts – der Task bewertet die laufende.
  test 'Mannschaft aus der Vorsaison deckt den Gast-Eintrag nicht' do
    club = club_with_guest_entry
    create(:team, club: club, league: create(:league, :previous_season, game_operation: @gast_go))

    run_task('DRY_RUN' => 'false')

    assert_empty club.reload.additional_game_operation_ids
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

  test 'mehrere Gast-Eintraege werden einzeln bewertet' do
    dritter_go = create(:game_operation)
    club = create(:club, state_association_id: @heim_sa.id, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => @heim_go.id },
      { 'home_game_operation' => false, 'game_operation_id' => @gast_go.id },
      { 'home_game_operation' => false, 'game_operation_id' => dritter_go.id }
    ])
    # Nur der dritte Spielbetrieb ist durch eine Liga gedeckt.
    create(:team, club: club, league: create(:league, :current_season, game_operation: dritter_go))

    run_task('DRY_RUN' => 'false')

    assert_equal [dritter_go.id], club.reload.additional_game_operation_ids
  end
end
