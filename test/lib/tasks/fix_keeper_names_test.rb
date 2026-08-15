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
  # ein erfundener Name. Geleert heisst dabei leere Zeichenkette, nicht NULL:
  # So schreibt es auch personName im Frontend, und knapp 1300 Zeilen je Spalte
  # tragen bereits ''.
  test 'ein Eintrag ganz ohne Namen wird geleert' do
    game = game_with(record_keeper_string: 'undefined, ')

    run_task

    assert_equal '', game.reload.record_keeper_string
  end

  # Gegenprobe: Bereits leere Zeilen sind kein Defekt und werden nicht
  # angefasst. Sie auf NULL zu ziehen haette 2600 Zeilen ohne Not veraendert.
  test 'eine bereits leere Zeichenkette bleibt, wie sie ist' do
    game = game_with(record_keeper_string: '', time_keeper_string: '')

    run_task

    game.reload
    assert_equal '', game.record_keeper_string
    assert_equal '', game.time_keeper_string
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

  # Die zweite, haeufig uebersehene Haelfte: Fehlte der VORNAME, entstand
  # "Ziegler, undefined". Auf Prod 49 bzw. 64 Eintraege. Die erste Fassung des
  # Tasks suchte per LIKE 'undefined,%' und hat davon keinen einzigen gesehen.
  test 'ein fehlender Vorname hinterlaesst ebenfalls kein "undefined"' do
    game = game_with(record_keeper_string: 'Ziegler, undefined',
                     time_keeper_string: 'Pennekamp, undefined')

    run_task

    game.reload
    assert_equal 'Ziegler', game.record_keeper_string
    assert_equal 'Pennekamp', game.time_keeper_string
  end

  # Ohne Leerzeichen nach dem Komma zerfiel der Wert frueher nicht, landete
  # komplett im Nachnamen und verlor dort sein Komma: "undefinedCarolina".
  # Der Task machte aus einem erkennbar kaputten Wert einen unerkennbaren.
  test 'ein fehlendes Leerzeichen nach dem Komma verschmilzt die Teile nicht' do
    game = game_with(record_keeper_string: 'undefined,Carolina')

    run_task

    assert_equal ', Carolina', game.reload.record_keeper_string
  end

  test 'Leerzeichen am Anfang und vor dem Komma fallen ebenfalls weg' do
    leading = game_with(record_keeper_string: ' Ziegler, Carolina')
    before_comma = game_with(record_keeper_string: 'Ziegler , Carolina')

    run_task

    assert_equal 'Ziegler, Carolina', leading.reload.record_keeper_string
    assert_equal 'Ziegler, Carolina', before_comma.reload.record_keeper_string
  end

  test 'ein Wert aus lauter Leerzeichen wird geleert' do
    game = game_with(record_keeper_string: '   ')

    run_task

    assert_equal '', game.reload.record_keeper_string
  end

  test 'ein Name ohne Vornamen behaelt seinen Nachnamen' do
    game = game_with(record_keeper_string: 'Ziegler, ')

    run_task

    assert_equal 'Ziegler', game.reload.record_keeper_string
  end

  # Das geschuetzte Leerzeichen kommt aus Word und PDF. JavaScripts trim()
  # entfernt es, Rubys strip nicht. Ohne [[:space:]] liefe die Bereinigung hier
  # auseinander mit dem, was das Frontend kuenftig speichert.
  test 'auch ein geschuetztes Leerzeichen wird entfernt' do
    game = game_with(record_keeper_string: "Ziegler, Carolina ")

    run_task

    assert_equal 'Ziegler, Carolina', game.reload.record_keeper_string
  end

  # Bei mehreren Kommata ist nicht mehr rekonstruierbar, wo die Grenze zwischen
  # Nach- und Vorname lag. Eine zu raten hiesse, Namensteile zwischen den
  # Feldern zu verschieben. Also nur trimmen, Struktur behalten.
  test 'mehrere Kommata werden nur getrimmt, nicht umgeschrieben' do
    game = game_with(record_keeper_string: 'van der, Berg, Jan ')

    run_task

    assert_equal 'van der, Berg, Jan', game.reload.record_keeper_string
  end

  # Eigenschaftsprüfung statt weiterer Einzelfaelle: Der Task darf keinen Wert
  # uebersehen, den keeper_normalize aendern wuerde. Die erste Fassung hatte
  # eine SQL-Vorauswahl, die genau daran scheiterte.
  test 'kein Wert bleibt liegen, den die Regel aendern wuerde' do
    dirty = [
      'undefined, Carolina', 'Ziegler, undefined', 'undefined,Carolina',
      'Ziegler, Carolina ', ' Ziegler, Carolina', 'Ziegler , Carolina',
      'undefined', 'undefined, ', '   ', "Ziegler, Carolina ",
      'van der, Berg, Jan '
    ]
    games = dirty.map { |v| game_with(record_keeper_string: v) }

    run_task
    run_task # zweiter Lauf: danach darf sich nichts mehr aendern

    games.each do |game|
      value = game.reload.record_keeper_string
      assert_no_match(/undefined/, value.to_s, "#{value.inspect} traegt noch 'undefined'")
      next if value.nil?

      assert_equal value.strip, value, "#{value.inspect} hat noch aussenliegende Leerzeichen"
    end
  end

  test 'ein Dry Run schreibt nichts' do
    game = game_with(record_keeper_string: 'undefined, Carolina')

    run_task({ 'DRY_RUN' => 'true' })

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
