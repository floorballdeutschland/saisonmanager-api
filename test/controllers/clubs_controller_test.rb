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

  test 'user_clubs_and_teams liefert SBK mit mehreren Spielbetrieben alle Vereine' do
    go1 = create(:game_operation)
    go2 = create(:game_operation)
    club1 = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go1.id }])
    club2 = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go2.id }])
    login(create(:user, permissions: [
      { 'user_group_id' => 2, 'game_operation_id' => go1.id },
      { 'user_group_id' => 2, 'game_operation_id' => go2.id }
    ]))

    get '/api/v2/user/clubs_and_teams'

    assert_response :success
    ids = JSON.parse(response.body).map { |c| c['id'] }
    assert_includes ids, club1.id
    assert_includes ids, club2.id
  end

  test 'admin_upload_logo akzeptiert ein quadratisches PNG' do
    club = create(:club)
    login(create(:user, :admin))

    post "/api/v2/admin/clubs/#{club.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :success
    assert club.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt ein nicht-quadratisches Bild mit 422 ab' do
    club = create(:club)
    login(create(:user, :admin))

    post "/api/v2/admin/clubs/#{club.id}/upload_logo", params: { logo: png_upload(200, 100, 'wide') }

    assert_response :unprocessable_entity
    assert_match(/quadratisch/, JSON.parse(response.body)['message'])
    assert_not club.reload.logo.attached?
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def square_png_upload(size)
    png_upload(size, size, "square#{size}")
  end

  def png_upload(width, height, name)
    require 'vips'
    path = Rails.root.join('tmp', "logo_test_#{name}.png").to_s
    Vips::Image.black(width, height).pngsave(path)
    Rack::Test::UploadedFile.new(path, 'image/png')
  end
end
