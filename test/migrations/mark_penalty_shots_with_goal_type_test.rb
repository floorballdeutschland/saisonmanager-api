require 'test_helper'
require Rails.root.join('db/migrate/20260913100000_mark_penalty_shots_with_goal_type')

# Daten-Migration zum gemeldeten Fehler vom 13.09.2026: Der Strafschuss wurde
# über den Pseudo-Strafcode 23 markiert, auf dem im Katalog inzwischen der Code
# 917 („Bodenspiel") liegt. Die Migration trennt beides in den Daten.
class MarkPenaltyShotsWithGoalTypeTest < ActiveSupport::TestCase
  def run_up
    ActiveRecord::Migration.suppress_messages { MarkPenaltyShotsWithGoalType.new.up }
  end

  def run_down
    ActiveRecord::Migration.suppress_messages { MarkPenaltyShotsWithGoalType.new.down }
  end

  def penalty_shot(extra = {})
    { 'id' => 1, 'period' => 1, 'time' => '5:00', 'event_type' => 'goal', 'event_team' => 'home',
      'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 7, 'penalty_code_id' => 23 }.merge(extra)
  end

  def bodenspiel_penalty(extra = {})
    { 'id' => 2, 'period' => 2, 'time' => '7:56', 'event_type' => 'penalty', 'event_team' => 'home',
      'home_goals' => 1, 'guest_goals' => 0, 'home_number' => 77,
      'penalty_id' => '1', 'penalty_code_id' => '23', 'penalty_code' => '917',
      'penalty_code_description' => 'Bodenspiel' }.merge(extra)
  end

  test 'up: aus dem Pseudo-Code wird die Torart' do
    game = create(:game, events: [penalty_shot])

    run_up

    event = game.reload.events.first
    assert_equal 'penalty_shot', event['goal_type']
    assert_not event.key?('penalty_code_id')
  end

  # Der Kern des Fehlers: Die Strafe trägt denselben Code, ist aber keine
  # Torart. Sie muss die Migration unverändert überstehen.
  test 'up: eine Strafe mit Grund 917 bleibt unangetastet' do
    game = create(:game, events: [bodenspiel_penalty])

    run_up

    event = game.reload.events.first
    assert_equal '23', event['penalty_code_id'].to_s
    assert_equal '1', event['penalty_id'].to_s
    assert_not event.key?('goal_type')
  end

  test 'up: beides im selben Spiel wird getrennt behandelt' do
    game = create(:game, events: [penalty_shot, bodenspiel_penalty])

    run_up

    shot, penalty = game.reload.events
    assert_equal 'penalty_shot', shot['goal_type']
    assert_not shot.key?('penalty_code_id')
    assert_not penalty.key?('goal_type')
    assert_equal '23', penalty['penalty_code_id'].to_s
  end

  # Altdaten tragen vereinzelt beide Markierungen. Das technische Tor behält
  # sein Label, so wie es die Anzeige schon immer aufgelöst hat.
  test 'up: technisches Tor mit anhängendem Pseudo-Code behält sein Label' do
    game = create(:game, events: [penalty_shot('goal_type' => 'technical')])

    run_up

    event = game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_not event.key?('penalty_code_id')
  end

  # Eine als Strafe erfasste Zeile ohne `penalty_id`: Angezeigt wurde sie vor wie
  # nach dieser Änderung als Tor „Strafschuss" (der Straf-Zweig verlangt seit
  # jeher eine penalty_id). Die Migration darf daraus aber keine dauerhafte
  # Torart machen und dabei den Strafgrund löschen -- er ist das Einzige, woran
  # sich so eine Zeile später noch als Strafe erkennen ließe.
  test 'up: als Strafe erfasste Zeile ohne penalty_id bleibt unangetastet' do
    game = create(:game, events: [penalty_shot('event_type' => 'penalty')])

    run_up

    event = game.reload.events.first
    assert_equal 23, event['penalty_code_id']
    assert_not event.key?('goal_type')
  end

  # Absicherung, kein Regressionsnachweis: Dieser Test lief auch mit dem Typtest
  # im WHERE durch. Ob er durchläuft, entscheidet aber der Ausführungsplan --
  # `jsonb_array_elements` steht in der FROM-Klausel und wird je Zeile
  # ausgewertet; ob PostgreSQL die Einschränkung auf `games` vorher anwendet, ist
  # nicht zugesichert. Mit dem CASE in der FROM-Klausel hängt es nicht mehr daran.
  # Migrationen laufen beim Deploy automatisch, ein Abbruch hier legte ihn lahm.
  test 'up: ein events, das kein Array ist, bricht die Migration nicht ab' do
    game = create(:game, events: [penalty_shot])
    krumm = create(:game)
    krumm.update_columns(events: {})

    run_up

    assert_equal 'penalty_shot', game.reload.events.first['goal_type']
    assert_equal({}, krumm.reload.events)
  end

  test 'up: Spiel ohne Ereignisse bleibt unangetastet' do
    game = create(:game, events: [])

    run_up

    assert_empty game.reload.events
  end

  test 'up: rührt updated_at nicht an' do
    game = create(:game, events: [penalty_shot])
    before = game.reload.updated_at

    run_up

    assert_equal before.to_f, game.reload.updated_at.to_f
  end

  test 'down: übersetzt die Torart zurück in den Pseudo-Code' do
    game = create(:game, events: [penalty_shot])

    run_up
    run_down

    event = game.reload.events.first
    assert_equal '23', event['penalty_code_id'].to_s
    assert_not event.key?('goal_type')
  end
end
