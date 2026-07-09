require 'test_helper'

class TeamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @team = create(:team, league: @league, club: @club, contact_email: 'team@example.org')
  end

  test 'admin_get_team erlaubt dem SBK des Spielbetriebs den Zugriff inkl. Kontaktdaten' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
    assert_equal 'team@example.org', JSON.parse(response.body)['contact_email']
  end

  test 'admin_get_team sperrt SBK eines fremden Spielbetriebs' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :forbidden
  end

  test 'admin_get_team erlaubt dem TM des Teams den Zugriff' do
    login(create(:user, :tm, team_id: @team.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
  end

  test 'admin_get_team erlaubt dem VM des Vereins den Zugriff' do
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
