require 'test_helper'
require 'rake'

# Tests für clubs:fix_string_game_operation_ids
# (lib/tasks/fix_string_game_operation_ids.rake).
#
# Die Vereinsanlage schrieb die Spielbetriebs-ID als Text in den
# game_operations_hash. Alle Abfragen darauf vergleichen per jsonb `@>` gegen
# eine Zahl, weshalb solche Vereine in keiner Vereinsliste auftauchen – und über
# die Oberfläche nicht reparierbar sind, weil man das Formular nur aus der Liste
# erreicht.
class FixStringGameOperationIdsTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?

    create(:setting, current_season_id: '18')
    @go = create(:game_operation, state_association_id: create(:state_association).id)
  end

  def run_task(env = {})
    task = Rake::Task['clubs:fix_string_game_operation_ids']
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    task.reenable
    capture_io { task.invoke }
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  # So sah ein über die Oberfläche angelegter Verein aus: ID als Text.
  def club_with_string_id(**attrs)
    create(:club, { game_operations_hash: [{ 'game_operation_id' => @go.id.to_s,
                                             'home_game_operation' => true }] }.merge(attrs))
  end

  test 'ein Verein mit Text-ID ist vorher unsichtbar und danach auffindbar' do
    club = club_with_string_id

    refute_includes @go.home_clubs.pluck(:id), club.id,
                    'Vorbedingung: mit Text-ID darf der Verein nicht gefunden werden'

    run_task('DRY_RUN' => 'false')

    assert_includes @go.home_clubs.pluck(:id), club.id
    assert_equal @go.id, club.reload.game_operations_hash.first['game_operation_id']
  end

  test 'Dry-Run ist Standard und schreibt nicht' do
    club = club_with_string_id

    out, = run_task
    assert_match '[DRY RUN]', out
    assert_match 'ES WURDE NICHTS GESCHRIEBEN', out
    assert_equal @go.id.to_s, club.reload.game_operations_hash.first['game_operation_id']
  end

  test 'Vereine mit korrekter Zahl bleiben unangetastet' do
    club = create(:club, game_operations_hash: [{ 'game_operation_id' => @go.id,
                                                  'home_game_operation' => true }])

    out, = run_task('DRY_RUN' => 'false')

    assert_match 'nichts zu tun', out
    assert_equal @go.id, club.reload.game_operations_hash.first['game_operation_id']
  end

  test 'Gast-Eintraege mit Text-ID werden mitrepariert' do
    guest_go = create(:game_operation, state_association_id: create(:state_association).id)
    club = create(:club, game_operations_hash: [
                    { 'game_operation_id' => @go.id.to_s, 'home_game_operation' => true },
                    { 'game_operation_id' => guest_go.id.to_s, 'home_game_operation' => false }
                  ])

    run_task('DRY_RUN' => 'false')

    assert_equal @go.id, club.reload.main_game_operation_id
    assert_equal [guest_go.id], club.additional_game_operation_ids
  end

  test 'laeuft ohne betroffene Vereine durch' do
    out, = run_task('DRY_RUN' => 'false')

    assert_match 'nichts zu tun', out
  end
end
