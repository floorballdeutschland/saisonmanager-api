require 'test_helper'

# GET user/team/:id/licenses: Das volle Lizenzwesen einer Mannschaft bekommt nur,
# wer sie verwaltet. Gegner und ausrichtende Vereine bekommen die Kaderliste des
# Aufstellungsdialogs, wie der Spielsekretariats-Link (api#906).
class ClubsTeamLicensesForeignTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @league = create(:league, :current_season, game_operation: create(:game_operation))
    @own_club = create(:club)
    @other_club = create(:club)
    @own_team = create(:team, league: @league, club: @own_club)
    @other_team = create(:team, league: @league, club: @other_club)

    @player = create(:player, birthdate: '2009-04-02', email: 'gegner@example.org',
                              deactivation_reason: 'intern', security_id: 'SEC-9',
                              clubs: [{ 'club_id' => @other_club.id, 'home_club' => true }],
                              with_licenses: [{ team: @other_team }])
    # Vereinsspieler ohne Lizenz fuer die Mannschaft: steht im vollen
    # Lizenzwesen unter other_players, gehoert Gegnern nicht.
    @unlicensed = create(:player, last_name: 'Ohnelizenz',
                                  clubs: [{ 'club_id' => @other_club.id, 'home_club' => true }])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  test 'VM eines Gegners bekommt nur die Kaderliste' do
    login_as(create(:user, :vm, club_id: @own_club.id))
    get "/api/v2/user/team/#{@other_team.id}/licenses"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[current_requests team], body.keys.sort
    row = body['current_requests'].sole
    assert_equal %w[birthdate current_status first_name id last_name suspension], row.keys.sort
    assert_equal @player.id, row['id']
    %w[gegner@example.org intern SEC-9 Ohnelizenz].each { |secret| assert_not_includes response.body, secret }
  end

  test 'TM eines Gegners bekommt nur die Kaderliste' do
    login_as(create(:user, :tm, team_id: @own_team.id))
    get "/api/v2/user/team/#{@other_team.id}/licenses"

    assert_response :success
    assert_not_includes response.body, 'gegner@example.org'
    assert_not_includes JSON.parse(response.body).keys, 'other_players'
  end

  test 'VM des eigenen Vereins bekommt weiter das volle Lizenzwesen' do
    login_as(create(:user, :vm, club_id: @other_club.id))
    get "/api/v2/user/team/#{@other_team.id}/licenses"

    assert_response :success
    assert_includes response.body, 'gegner@example.org'
    assert_includes JSON.parse(response.body).keys, 'other_players'
  end

  test 'TM der Mannschaft bekommt weiter das volle Lizenzwesen' do
    login_as(create(:user, :tm, team_id: @other_team.id))
    get "/api/v2/user/team/#{@other_team.id}/licenses"

    assert_response :success
    assert_includes response.body, 'gegner@example.org'
  end

  test 'ohne Beteiligung an der Liga bleibt es bei 403' do
    login_as(create(:user, :vm, club_id: create(:club).id))
    get "/api/v2/user/team/#{@other_team.id}/licenses"
    assert_response :forbidden
  end
end
