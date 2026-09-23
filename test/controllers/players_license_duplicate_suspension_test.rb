require 'test_helper'

# Doppelantrag trotz vorgemerkter Team-Sperre (#725, Folge in #748).
#
# write_suspended_status! stempelt den Sperr-Eintrag sofort, die Sperre gilt
# aber erst ab valid_from. suspension_for_team greift davor noch nicht. Las die
# Doppelantrags-Pruefung den aktuellen Status, galt die gesperrte Lizenz als
# nicht aktiv, und ein zweiter Antrag ohne Sperr-Eintrag ging durch.
class PlayersLicenseDuplicateSuspensionTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @club = create(:club)
    @league = create(:league, :current_season)
    @team = create(:team, league: @league, club: @club)
    @vm = create(:user, :vm, club_id: @club.id)
    @admin = create(:user, :admin)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  test 'zweiter Antrag trotz vorgemerkter Team-Sperre wird als Doppelung abgelehnt' do
    player = create(:player,
                    clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.day.ago.iso8601 }],
                    with_licenses: [{ team: @team, status: License::APPROVED }])
    player.suspend!(user_id: @admin.id, team_id: @team.id, valid_from: Date.current + 7, games_total: 2)
    assert_equal License::SUSPENDED, License.current_status_id(player.reload.licenses.first)

    login_as(@vm)
    post "/api/v2/user/players/#{player.id}/request_license", params: { team_id: @team.id }, as: :json

    assert_response :unprocessable_entity
    assert_match 'schon einen Lizenzantrag', JSON.parse(response.body)['message']
    assert_equal 1, player.reload.licenses.size
  end
end
