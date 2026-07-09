require 'test_helper'

class ClubsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
  end

  test 'admin_club_all liefert TM die schlanke Liste ohne contact_email' do
    club = create(:club, contact_email: 'geheim@example.org')
    team = create(:team, club: club)
    login(create(:user, :tm, team_id: team.id))

    get '/api/v2/admin/clubs/all'

    assert_response :success
    body = JSON.parse(response.body)
    assert(body.any? { |c| c['id'] == club.id })
    assert_not body.any? { |c| c.key?('contact_email') }, 'contact_email darf nicht enthalten sein'
  end

  test 'admin_club_all ist für reine Schiri-Logins gesperrt' do
    login(create(:user, permissions: [{ 'user_group_id' => 6 }]))

    get '/api/v2/admin/clubs/all'

    assert_response :forbidden
  end

  test 'admin_club liefert dem SBK des Spielbetriebs den vollen Datensatz' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    club = create(:club, contact_email: 'kontakt@example.org',
                         game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go.id }])
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :success
    assert_equal 'kontakt@example.org', JSON.parse(response.body)['contact_email']
  end

  test 'admin_club erlaubt SBK den Lesezugriff auf Vereine seines Gast-Spielbetriebs' do
    home_sa = create(:state_association)
    home_go = create(:game_operation, state_association_id: home_sa.id)
    guest_sa = create(:state_association)
    guest_go = create(:game_operation, state_association_id: guest_sa.id)
    # Verein gehört home_go, spielt aber als Gast in guest_go mit
    club = create(:club, contact_email: 'kontakt@example.org',
                         game_operations_hash: [
                           { 'home_game_operation' => true, 'game_operation_id' => home_go.id },
                           { 'home_game_operation' => false, 'game_operation_id' => guest_go.id }
                         ])
    login(create(:user, :sbk_scoped, game_operation_id: guest_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    # deckungsgleich mit der Vereinsliste (Club.admin_user_clubs), die den
    # Verein über den Gast-Spielbetrieb ebenfalls anzeigt
    assert_response :success
    assert_equal 'kontakt@example.org', JSON.parse(response.body)['contact_email']
  end

  test 'admin_club ist für SBK eines fremden Spielbetriebs gesperrt' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    club = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go.id }])
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :forbidden
  end

  test 'admin_club erlaubt LV-SBK den Lesezugriff auf freigegebene Vereine' do
    grantor_sa = create(:state_association)
    grantor_go = create(:game_operation, state_association_id: grantor_sa.id)
    recipient_sa = create(:state_association)
    recipient_go = create(:game_operation, state_association_id: recipient_sa.id)
    club = create(:club, state_association_id: grantor_sa.id,
                         game_operations_hash: [{ 'home_game_operation' => true,
                                                  'game_operation_id' => grantor_go.id }])
    StateAssociationRelease.create!(
      grantor_state_association_id: grantor_sa.id,
      recipient_game_operation_id: recipient_go.id,
      season_id: Setting.current_season_id
    )
    login(create(:user, :sbk_scoped, game_operation_id: recipient_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :success
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
