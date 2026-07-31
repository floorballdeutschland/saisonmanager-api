require 'test_helper'

# Game#url muss auf die tatsächlich vorhandene Frontend-Route der öffentlichen
# Spielseite zeigen: /<game_operation_slug>/<league_id>/spiel/<game_id>. Das
# Verbandssegment ist GameOperation#slug, weil der Router dagegen vergleicht.
class GameUrlTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @club = create(:club)
    @arena = create(:arena)
  end

  test 'Verbandssegment nutzt den short_name als Slug' do
    game = build_game(create(:game_operation, short_name: 'FD', path: nil))

    assert_equal "#{FrontendUrl.base}/fd/#{game.league.id}/spiel/#{game.id}", game.url
  end

  test 'ein gesetzter path hat Vorrang vor dem short_name' do
    game = build_game(create(:game_operation, short_name: 'FD', path: 'bundesliga'))

    assert_equal "#{FrontendUrl.base}/bundesliga/#{game.league.id}/spiel/#{game.id}", game.url
  end

  test 'short_name mit Punkt und Leerzeichen wird parameterisiert, nicht nur kleingeschrieben' do
    game = build_game(create(:game_operation, short_name: '1. FBL', path: nil))

    assert_equal "#{FrontendUrl.base}/1-fbl/#{game.league.id}/spiel/#{game.id}", game.url
  end

  private

  def build_game(game_operation)
    league = create(:league, game_operation: game_operation)
    game_day = GameDay.create!(league: league, arena: @arena, club: @club, number: 1, date: '2026-01-01')
    Game.create!(
      game_day: game_day,
      home_team: create(:team, league: league, club: @club),
      guest_team: create(:team, league: league, club: @club),
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
  end
end
