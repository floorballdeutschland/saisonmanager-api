require 'test_helper'

# Lizenzuebersicht einer Spielgemeinschaft (GET user/team/:id/licenses).
#
# Fall: Spieler mit Stammverein A und Freigabe fuer Verein B, beide Vereine
# bilden die SG. Er steht in beiden Vereinslisten, darf in der Uebersicht aber
# nur einmal erscheinen (SG Bloherfelde / Sedelsberg, 30.09.2026).
class ClubsTeamLicensesSyndicateTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club, game_operation: @game_operation)
    @partner_club = create(:club, game_operation: @game_operation)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club, syndicate: true, syndicate_clubs: [@partner_club.id])
    @vm = create(:user, :vm, club_id: @club.id)
    @player = create(:player, clubs: [
      { 'club_id' => @partner_club.id, 'home_club' => true, 'created_at' => 2.days.ago.iso8601 },
      { 'club_id' => @club.id, 'home_club' => false, 'created_at' => 1.day.ago.iso8601,
        'valid_until' => 1.year.from_now.iso8601 }
    ])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def team_licenses
    login_as(@vm)
    get "/api/v2/user/team/#{@team.id}/licenses"
    assert_response :success
    JSON.parse(response.body)
  end

  test 'ein Spieler mit Lizenz steht nur einmal unter den Antraegen' do
    license = {
      'id' => 'l1', 'team_id' => @team.id, 'season_id' => @league.season_id,
      'league_class_id' => @league.league_class_id, 'valid_until' => 1.year.from_now.to_date.iso8601,
      'history' => [{ 'license_status_id' => License::REQUESTED, 'created_at' => 1.hour.ago.iso8601 }]
    }
    @player.update!(licenses: [license])

    ids = team_licenses['current_requests'].map { |p| p['id'] }

    assert_equal 1, ids.count(@player.id)
  end

  test 'ein Spieler ohne Lizenz steht nur einmal in der Auswahl' do
    ids = team_licenses['other_players'].map { |p| p['id'] }

    assert_equal 1, ids.count(@player.id)
  end
end
