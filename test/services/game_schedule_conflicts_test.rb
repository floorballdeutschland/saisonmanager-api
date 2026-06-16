require 'test_helper'

class GameScheduleConflictsTest < ActiveSupport::TestCase
  setup do
    @go = GameOperation.create!(name: 'GO', short_name: 'GO')
    @league = League.create!(game_operation: @go, name: 'Liga', season_id: '18',
                             table_modus: 'classic', periods: 3, game_duration_minutes: 60)
    @club = Club.create!
    @arena = Arena.create!(name: 'Halle A', city: 'Stadt')
    @other_arena = Arena.create!(name: 'Halle B', city: 'Stadt')
  end

  # Erzeugt ein Spiel an einem eigenen Spieltag in der gegebenen Arena.
  def build_game(arena:, start_time:, date: '2026-02-01')
    gd = GameDay.create!(league: @league, arena: arena, club: @club, number: 1, date: date)
    home = Team.create!(league: @league, club: @club, name: 'H')
    guest = Team.create!(league: @league, club: @club, name: 'G')
    Game.create!(game_day: gd, home_team: home, guest_team: guest, start_time: start_time,
                 forfait: 0, overtime: false, legacy: false, events: [],
                 players: { 'home' => [], 'guest' => [] })
  end

  test 'überschneidende Spiele in derselben Arena ergeben einen Konflikt' do
    existing = build_game(arena: @arena, start_time: '14:00') # 14:00–15:00
    conflicts = GameScheduleConflicts.new(
      game_day: existing.game_day, start_time: '14:30'
    ).arena_conflicts
    assert_includes conflicts.map(&:id), existing.id
  end

  test 'nicht überschneidende Zeiten ergeben keinen Konflikt' do
    existing = build_game(arena: @arena, start_time: '14:00') # 14:00–15:00
    conflicts = GameScheduleConflicts.new(
      game_day: existing.game_day, start_time: '15:30'
    ).arena_conflicts
    assert_empty conflicts
  end

  test 'direkt anschließende Spiele (Ende == Start) überschneiden sich nicht' do
    existing = build_game(arena: @arena, start_time: '14:00') # 14:00–15:00
    conflicts = GameScheduleConflicts.new(
      game_day: existing.game_day, start_time: '15:00'
    ).arena_conflicts
    assert_empty conflicts
  end

  test 'andere Arena ergibt keinen Konflikt' do
    build_game(arena: @arena, start_time: '14:00')
    proposed = GameDay.create!(league: @league, arena: @other_arena, club: @club,
                               number: 2, date: '2026-02-01')
    conflicts = GameScheduleConflicts.new(game_day: proposed, start_time: '14:30').arena_conflicts
    assert_empty conflicts
  end

  test 'das geprüfte Spiel selbst wird über exclude_game_id ausgenommen' do
    existing = build_game(arena: @arena, start_time: '14:00')
    conflicts = GameScheduleConflicts.new(
      game_day: existing.game_day, start_time: '14:00', exclude_game_id: existing.id
    ).arena_conflicts
    assert_empty conflicts
  end

  test 'Konflikt über verschiedene Spieltage in derselben Arena' do
    existing = build_game(arena: @arena, start_time: '14:00') # eigener Spieltag/Liga
    other_league = League.create!(game_operation: @go, name: 'Liga 2', season_id: '18',
                                  table_modus: 'classic', periods: 3, game_duration_minutes: 60)
    proposed_gd = GameDay.create!(league: other_league, arena: @arena, club: @club,
                                  number: 9, date: '2026-02-01')
    conflicts = GameScheduleConflicts.new(game_day: proposed_gd, start_time: '14:30').arena_conflicts
    assert_includes conflicts.map(&:id), existing.id
  end

  test 'fehlende Startzeit ergibt keine Konflikte' do
    existing = build_game(arena: @arena, start_time: '14:00')
    conflicts = GameScheduleConflicts.new(
      game_day: existing.game_day, start_time: nil
    ).arena_conflicts
    assert_empty conflicts
  end

  test 'unparsebare Startzeit ergibt keine Konflikte' do
    existing = build_game(arena: @arena, start_time: '14:00')
    conflicts = GameScheduleConflicts.new(
      game_day: existing.game_day, start_time: '25:99'
    ).arena_conflicts
    assert_empty conflicts
  end

  test 'duration_minutes-Override verlängert das Fenster und erzeugt so einen Konflikt' do
    later = build_game(arena: @arena, start_time: '15:00') # 15:00–16:00
    # Vorschlag 14:00 mit Default 60 min (14:00–15:00) grenzt nur an → kein Konflikt.
    default = GameScheduleConflicts.new(
      game_day: later.game_day, start_time: '14:00'
    ).arena_conflicts
    assert_empty default
    # Mit 120 min Override (14:00–16:00) überschneidet es das spätere Spiel.
    overridden = GameScheduleConflicts.new(
      game_day: later.game_day, start_time: '14:00', duration_minutes: 120
    ).arena_conflicts
    assert_includes overridden.map(&:id), later.id
  end
end
