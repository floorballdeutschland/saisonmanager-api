require 'test_helper'
require 'rake'

# Tests für keeper_names:cleanup (lib/tasks/fix_keeper_names.rake): räumt
# "undefined" als Nachnamen und Leerzeichen am Ende aus den Freitext-Namen des
# Spielberichts. Beides ist im Bestand entstanden, weil das Frontend die beiden
# Eingaben ungetrimmt und ohne Behandlung fehlender Teile zusammensetzte.
class FixKeeperNamesTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task['keeper_names:cleanup']
    @task.reenable

    create(:setting)
    league = create(:league, game_operation: create(:game_operation))
    @game_day = GameDay.create!(league: league, arena: create(:arena), club: create(:club),
                                number: 1, date: '2026-01-01')
  end

  def run_task(env = { 'DRY_RUN' => 'false' })
    saved = ENV.to_hash.slice(*env.keys)
    env.each { |k, v| ENV[k] = v }
    @task.reenable
    @task.invoke
  ensure
    env.each_key { |k| ENV[k] = saved[k] }
  end

  def game_with(**attrs)
    Game.create!(
      game_day: @game_day, started: false, ended: false, forfait: 0,
      overtime: false, legacy: false, events: [], players: { 'home' => [], 'guest' => [] },
      **attrs
    )
  end

  test 'ein fehlender Nachname hinterlaesst kein "undefined" mehr' do
    game = game_with(record_keeper_string: 'undefined, Carolina')

    run_task

    assert_equal ', Carolina', game.reload.record_keeper_string
  end

  test 'das Leerzeichen am Ende faellt weg' do
    game = game_with(record_keeper_string: 'Ziegler, Carolina ')

    run_task

    assert_equal 'Ziegler, Carolina', game.reload.record_keeper_string
  end

  test 'der Zeitnehmer wird genauso behandelt' do
    game = game_with(time_keeper_string: 'undefined, Julian ')

    run_task

    assert_equal ', Julian', game.reload.time_keeper_string
  end

  # Bleibt nach dem Aufraeumen nichts uebrig, ist ein leeres Feld ehrlicher als
  # ein erfundener Name.
  test 'ein Eintrag ganz ohne Namen wird geleert' do
    game = game_with(record_keeper_string: 'undefined, ')

    run_task

    assert_nil game.reload.record_keeper_string
  end

  # Der Task fasst nur an, was eines der beiden Muster trifft. Ein sauberer
  # Name muss ihn unveraendert ueberstehen, sonst schreibt er den halben
  # Bestand ohne Not um.
  test 'saubere Namen bleiben unangetastet' do
    game = game_with(record_keeper_string: 'Ziegler, Carolina',
                     time_keeper_string: 'Pennekamp, Julian')

    run_task

    game.reload
    assert_equal 'Ziegler, Carolina', game.record_keeper_string
    assert_equal 'Pennekamp, Julian', game.time_keeper_string
  end

  test 'ein Dry Run schreibt nichts' do
    game = game_with(record_keeper_string: 'undefined, Carolina')

    run_task({})

    assert_equal 'undefined, Carolina', game.reload.record_keeper_string
  end

  test 'ein zweiter Lauf findet nichts mehr' do
    game = game_with(record_keeper_string: 'Ziegler, Carolina ')

    run_task
    first = game.reload.record_keeper_string
    run_task

    assert_equal first, game.reload.record_keeper_string
  end
end
