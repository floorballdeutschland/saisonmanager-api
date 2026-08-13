require 'test_helper'

module Admin
  class InfoLinksControllerTest < ActionDispatch::IntegrationTest
    URL = 'https://floorball.de/wp-content/uploads/2026/06/info.pdf'.freeze

    setup do
      @setting = create(:setting)
      @sa = create(:state_association)
      @go = create(:game_operation, state_association_id: @sa.id)
    end

    test 'Admin sieht alle bekannten Keys, auch ohne gepflegte URL' do
      login(create(:user, :admin))

      get '/api/v2/admin/info_links'
      assert_response :success
      body = JSON.parse(response.body)
      keys = body.map { |link| link['key'] }
      assert_equal Setting::INFO_LINK_KEYS, keys
      assert_nil body.first['url']
    end

    test 'Admin hinterlegt eine URL' do
      login(create(:user, :admin))

      patch '/api/v2/admin/info_links/minor_privacy_bundesliga', params: { info_link: { url: URL } }
      assert_response :ok
      assert_equal URL, JSON.parse(response.body)['url']
      assert_equal URL, @setting.reload.info_links.dig('minor_privacy_bundesliga', 'url')
    end

    test 'Leere URL entfernt den Link' do
      login(create(:user, :admin))
      @setting.update!(info_links: { 'minor_privacy_bundesliga' => { 'url' => URL } })

      patch '/api/v2/admin/info_links/minor_privacy_bundesliga', params: { info_link: { url: '' } }
      assert_response :ok
      assert_nil JSON.parse(response.body)['url']
      assert_empty @setting.reload.info_links
    end

    test 'URL ohne http(s) → 422, alter Wert bleibt' do
      login(create(:user, :admin))
      @setting.update!(info_links: { 'minor_privacy_bundesliga' => { 'url' => URL } })

      patch '/api/v2/admin/info_links/minor_privacy_bundesliga', params: { info_link: { url: 'floorball.de/info.pdf' } }
      assert_response :unprocessable_entity
      assert_equal URL, @setting.reload.info_links.dig('minor_privacy_bundesliga', 'url')
    end

    test 'Unbekannter Key → 404' do
      login(create(:user, :admin))

      patch '/api/v2/admin/info_links/erfundener_key', params: { info_link: { url: URL } }
      assert_response :not_found
    end

    test 'globale SBK (FD) darf pflegen' do
      login(create(:user, :sbk_global))

      patch '/api/v2/admin/info_links/minor_privacy_bundesliga', params: { info_link: { url: URL } }
      assert_response :ok
    end

    test 'gescopte SBK darf nur lesen' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      get '/api/v2/admin/info_links'
      assert_response :success

      patch '/api/v2/admin/info_links/minor_privacy_bundesliga', params: { info_link: { url: URL } }
      assert_response :forbidden
      assert_empty @setting.reload.info_links
    end

    test 'VM darf weder lesen noch pflegen' do
      login(create(:user, :vm, club_id: 1))

      get '/api/v2/admin/info_links'
      assert_response :forbidden

      patch '/api/v2/admin/info_links/minor_privacy_bundesliga', params: { info_link: { url: URL } }
      assert_response :forbidden
    end

    test 'init liefert gepflegte Links an alle Aufrufer aus' do
      @setting.update!(info_links: { 'minor_privacy_bundesliga' => { 'url' => URL } })
      login(create(:user, :vm, club_id: 1))

      get '/api/v2/init.json'
      assert_response :success
      assert_equal URL, JSON.parse(response.body).dig('info_links', 'minor_privacy_bundesliga')
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
