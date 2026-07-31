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

  # Issue #275: Banner nehmen dieselben Formate wie die Logos, damit in derselben
  # Verwaltungsoberfläche nicht zweierlei Recht gilt.
  test 'admin_upload_banner nimmt ein PNG im Querformat an' do
    login(create(:user, :admin))

    post "/api/v2/admin/game_operations/#{@go.id}/upload_banner",
         params: { banner: banner_upload(1200, 200, 'go_banner') }

    assert_response :success
    assert @go.reload.banner.attached?
  end

  test 'admin_upload_banner lehnt ein SVG ab' do
    login(create(:user, :admin))
    path = Rails.root.join('tmp', 'go_banner.svg').to_s
    File.write(path, '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>')

    post "/api/v2/admin/game_operations/#{@go.id}/upload_banner",
         params: { banner: Rack::Test::UploadedFile.new(path, 'image/svg+xml') }

    assert_response :unprocessable_entity
    assert_match(/Dateiformat/, JSON.parse(response.body)['message'])
    assert_not @go.reload.banner.attached?
  end

  private

  def banner_upload(width, height, name)
    require 'vips'
    path = Rails.root.join('tmp', "#{name}.png").to_s
    Vips::Image.black(width, height).write_to_file(path)
    Rack::Test::UploadedFile.new(path, 'image/png')
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
