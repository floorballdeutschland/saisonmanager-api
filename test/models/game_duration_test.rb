require 'test_helper'

# Konfigurierbare Spieldauer + Zeitfenster (Grundlage für die Hallenbelegungs-
# und Schiedsrichter-Konfliktprüfung).
class GameDurationTest < ActiveSupport::TestCase
  setup do
    # Sauberes Setting mit Hash-systems (die Fixture liefert systems als JSON-String).
    create(:setting, current_season_id: '18')
    @go = GameOperation.create!(name: 'GO', short_name: 'GO')
    @club = Club.create!
    @arena = Arena.create!(name: 'Halle', city: 'Stadt')
  end

  def build_league(**attrs)
    League.create!({ game_operation: @go, name: 'Liga', season_id: '18',
                     table_modus: 'classic' }.merge(attrs))
  end

  def build_game(league, start_time:)
    gd = GameDay.create!(league: league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    home = Team.create!(league: league, club: @club, name: 'H')
    guest = Team.create!(league: league, club: @club, name: 'G')
    Game.create!(game_day: gd, home_team: home, guest_team: guest, start_time: start_time,
                 forfait: 0, overtime: false, legacy: false, events: [],
                 players: { 'home' => [], 'guest' => [] })
  end

  test 'effective_game_duration_minutes: Liga-Override hat Vorrang' do
    league = build_league(periods: 3, game_duration_minutes: 75)
    assert_equal 75, league.effective_game_duration_minutes
  end

  test 'effective_game_duration_minutes: globaler Default greift ohne Liga-Override' do
    Setting.first.update!(systems: { '1' => { 'current_season_id' => 18, 'game_duration_minutes' => 95 } })
    league = build_league(periods: 3)
    assert_equal 95, league.effective_game_duration_minutes
  end

  test 'effective_game_duration_minutes: perioden-basierter Fallback (Großfeld 120, sonst 60)' do
    assert_equal 120, build_league(periods: 3).effective_game_duration_minutes
    assert_equal 60, build_league(periods: 2).effective_game_duration_minutes
  end

  test 'end_date nutzt die effektive Dauer' do
    league = build_league(periods: 3, game_duration_minutes: 90)
    game = build_game(league, start_time: '14:00')
    assert_equal 90 * 60, (game.end_date - game.start_date).to_i
  end

  test 'occupancy_window spannt Start...Ende' do
    league = build_league(periods: 3, game_duration_minutes: 90)
    game = build_game(league, start_time: '14:00')
    assert_equal game.start_date, game.occupancy_window.begin
    assert_equal game.end_date, game.occupancy_window.end
  end

  test 'occupancy_window ist nil ohne Startzeit' do
    league = build_league(periods: 3)
    game = build_game(league, start_time: nil)
    assert_nil game.occupancy_window
  end
end
