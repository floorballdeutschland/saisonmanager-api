require 'test_helper'

class GameOperationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation)
  end

  test 'banner_link darf ein Admin eines fremden Spielbetriebs nicht ändern' do
    other_go = create(:game_operation)
    scoped_admin = create(:user, permissions: [{ 'user_group_id' => 1, 'game_operation_id' => other_go.id }])
    login(scoped_admin)

    patch "/api/v2/admin/game_operations/#{@go.id}/banner_link",
          params: { banner_link_url: 'https://example.org' }

    assert_response :forbidden
  end

  test 'banner_link darf der Admin des Spielbetriebs ändern' do
    scoped_admin = create(:user, permissions: [{ 'user_group_id' => 1, 'game_operation_id' => @go.id }])
    login(scoped_admin)

    patch "/api/v2/admin/game_operations/#{@go.id}/banner_link",
          params: { banner_link_url: 'https://example.org' }

    assert_response :success
    assert_equal 'https://example.org', @go.reload.banner_link_url
  end

  test 'banner_link darf der globale Admin ändern' do
    login(create(:user, :admin))

    patch "/api/v2/admin/game_operations/#{@go.id}/banner_link",
          params: { banner_link_url: 'https://example.org' }

    assert_response :success
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
