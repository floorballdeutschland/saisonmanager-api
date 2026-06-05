require 'test_helper'

class Admin::SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @setting = create(:setting, current_season_id: '17')
    @admin = create_user(user_group_id: 1, game_operation_id: 0)
    @vm    = create_user(user_group_id: 4, game_operation_id: 0)
  end

  # --- create_season ---

  test 'Admin erstellt Saison mit gültigem Namen → 201 mit min_league_id und min_team_id' do
    login(@admin)
    post '/api/v2/admin/settings/seasons', params: { name: 'Saison 2026/27' }
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal 'Saison 2026/27', body['name']
    assert body.key?('id')
    assert body.key?('min_league_id')
    assert body.key?('min_team_id')
    assert_equal false, body['current']
  end

  test 'Leerer Name → 422' do
    login(@admin)
    post '/api/v2/admin/settings/seasons', params: { name: '' }
    assert_response :unprocessable_entity
  end

  test 'VM versucht Saison anzulegen → 403' do
    login(@vm)
    post '/api/v2/admin/settings/seasons', params: { name: 'Saison 2026/27' }
    assert_response :forbidden
  end

  # --- update_season ---

  test 'Admin aktiviert existierende Saison → 200 mit neuer current_season_id' do
    login(@admin)
    patch '/api/v2/admin/settings/current_season', params: { season_id: 18 }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 18, body['current_season_id']
  end

  test 'Admin aktiviert nicht-existierende Saison → 422' do
    login(@admin)
    patch '/api/v2/admin/settings/current_season', params: { season_id: 9999 }
    assert_response :unprocessable_entity
  end

  private

  def create_user(user_group_id:, game_operation_id:)
    User.create!(
      user_name: "settingsuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
      teams: []
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
