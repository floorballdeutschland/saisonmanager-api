require 'test_helper'

# Ausgabe des Overlay-Zugangs. Die Rechteprüfung ist dieselbe wie beim
# Sekretariatslink (GameDayLinkAuthorization); geprüft wird hier, dass sie am
# neuen Controller wirklich hängt und dass der Klartext des Tokens nur ein
# einziges Mal herausgeht.
class GameDayOverlayLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @game_day = create(:game_day, league: @league, club: @club)
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league)
    create(:game, game_day: @game_day, home_team: @home, guest_team: @guest)
  end

  test 'Admin bekommt Token und fertige URLs' do
    login(create(:user, :admin))

    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :created
    body = JSON.parse(response.body)
    assert body['token'].present?
    assert_includes body['overlay_url'], "/overlay/index.html?token=#{body['token']}"
    assert_includes body['dock_url'], "/overlay/dock.html?token=#{body['token']}"
    assert body['expires_at'].present?
  end

  test 'SBK des Spielbetriebs darf' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :created
  end

  test 'Vereinsmanager des ausrichtenden Vereins darf' do
    login(create(:user, :vm, club_id: @club.id))

    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :created
  end

  test 'Teammanager der Heimmannschaft darf' do
    login(create(:user, :tm, team_id: @home.id))

    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :created
  end

  # Gestreamt wird aus der Halle des Ausrichters. Der Gast war bis 1.98.x
  # mitberechtigt, weil der Concern jede beteiligte Mannschaft durchließ.
  test 'Vereinsmanager des Gastvereins darf nicht' do
    login(create(:user, :vm, club_id: @guest.club_id))

    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :forbidden
  end

  test 'Teammanager der Gastmannschaft darf nicht' do
    login(create(:user, :tm, team_id: @guest.id))

    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :forbidden
  end

  test 'SBK eines fremden Spielbetriebs darf nicht' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :forbidden
  end

  test 'ohne Anmeldung gibt es kein Token' do
    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :unauthorized
  end

  test 'show nennt den Zustand, aber nie das Token' do
    user = create(:user, :admin)
    login(user)
    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"
    raw_token = JSON.parse(response.body)['token']

    get "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['active']
    assert_equal user.fullname, body['created_by']
    assert_not_includes response.body, raw_token, 'Der Klartext darf nur einmal herausgehen'
  end

  test 'show meldet einen Spieltag ohne Zugang' do
    login(create(:user, :admin))

    get "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_response :success
    assert_equal false, JSON.parse(response.body)['active']
  end

  test 'destroy zieht den Zugang zurueck' do
    login(create(:user, :admin))
    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_difference('GameDayOverlayLink.count', -1) do
      delete "/api/v2/user/game_days/#{@game_day.id}/overlay_link"
    end

    assert_response :success
  end

  test 'ein zweiter Aufruf ersetzt den bestehenden Zugang, statt einen zweiten anzulegen' do
    login(create(:user, :admin))
    post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"

    assert_no_difference('GameDayOverlayLink.count') do
      post "/api/v2/user/game_days/#{@game_day.id}/overlay_link"
    end
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
