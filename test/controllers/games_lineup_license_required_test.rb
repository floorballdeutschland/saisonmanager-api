require 'test_helper'

# Ein Spieler ohne jeden Lizenzeintrag fuer die aufstellende Mannschaft kommt
# nicht mehr in den Kader. Bis dahin gab es nur eine Warnung, und im Spiel 61889
# stand so der Schiedsrichter, ein Spieler einer anderen Mannschaft, im
# Heimkader. Alles mit Lizenzeintrag laeuft weiter ueber die Warnung, siehe
# games_requested_license_playable_test.rb und games_lineup_suspension_test.rb.
class GamesLineupLicenseRequiredTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league')
    @club = create(:club, game_operation: @go)
    @home_team = create(:team, league: @league, club: @club)
    @other_team = create(:team, league: @league, club: create(:club))
    game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club,
                               number: 1, date: '2026-01-10')
    @game = Game.create!(game_day: game_day, home_team: @home_team, guest_team: create(:team, league: @league),
                         forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })

    login(create(:user, :admin))
  end

  test 'ohne Lizenzeintrag wird der Spieler abgewiesen' do
    player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: player.id, trikot_number: 7 }

    assert_response :unprocessable_entity
    assert_match(/Kein Lizenzantrag/, JSON.parse(response.body)['message'])
    assert_empty @game.reload.players['home']
  end

  # Der Fall aus 61889: erteilte Lizenz, aber fuer eine andere Mannschaft.
  test 'eine Lizenz fuer eine andere Mannschaft reicht nicht' do
    player = create(:player, clubs: [{ 'club_id' => @other_team.club_id, 'home_club' => true }],
                             with_licenses: [{ team: @other_team, status: License::APPROVED }])

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: player.id, trikot_number: 19 }

    assert_response :unprocessable_entity
    assert_empty @game.reload.players['home']
  end

  test 'mit erteilter Lizenz fuer die Mannschaft wird aufgestellt' do
    player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                             with_licenses: [{ team: @home_team, status: License::APPROVED }])

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: player.id, trikot_number: 7 }

    assert_response :success
    assert_nil JSON.parse(response.body)['warning']
    assert_equal([player.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
