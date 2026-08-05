require 'test_helper'

module Admin
  class ApiKeysControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @key = create(:api_key, name: 'Partner-Key')
    end

    test 'Liste nennt die Zugriffe der letzten 30 Tage' do
      2.times { ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'leagues#schedule') }
      ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'teams#stats', date: Date.current - 10)
      # Älter als das Fenster, darf nicht mitzählen.
      ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'teams#stats', date: Date.current - 40)

      login(@admin)
      get '/api/v2/admin/api_keys'

      assert_response :success
      entry = JSON.parse(response.body).find { |k| k['id'] == @key.id }
      assert_equal 3, entry['usage_30_days']
      assert_nil entry['application'], 'Ein manuell angelegter Key hat keinen Antrag'
    end

    test 'Liste zeigt den Antrag hinter einem genehmigten Key' do
      application = create(:api_key_application, organisation: 'Floorball Beispielstadt')
      application.approve!(@admin.id)
      application.reveal_key!

      login(@admin)
      get '/api/v2/admin/api_keys'

      assert_response :success
      entry = JSON.parse(response.body).find { |k| k['id'] == application.reload.api_key_id }
      assert_equal 'Floorball Beispielstadt', entry.dig('application', 'organisation')
      assert_equal application.email, entry.dig('application', 'email')
    end

    test 'Nutzungsansicht liefert Tage, Monate und Endpunkte' do
      3.times { ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'leagues#schedule') }
      ApiKeyUsage.increment!(api_key_id: @key.id, endpoint: 'teams#stats')

      login(@admin)
      get "/api/v2/admin/api_keys/#{@key.id}/usage"

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 30, body['last_30_days'].length
      assert_equal 12, body['last_year'].length
      assert_equal 4, body['last_30_days'].last['count']
      assert_equal [{ 'endpoint' => 'leagues#schedule', 'count' => 3 },
                    { 'endpoint' => 'teams#stats', 'count' => 1 }],
                   body['by_endpoint']
      assert_equal 'Partner-Key', body['name']
    end

    test 'Nutzungsansicht eines Keys ohne Zugriffe bleibt leer' do
      login(@admin)
      get "/api/v2/admin/api_keys/#{@key.id}/usage"

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal [], body['by_endpoint']
      total = body['last_30_days'].sum { |d| d['count'] }
      assert_equal 0, total
    end

    test 'SBK hat keinen Zugriff auf die Nutzungsansicht' do
      login(create(:user, :sbk_global))
      get "/api/v2/admin/api_keys/#{@key.id}/usage"

      assert_response :forbidden
    end

    # Der Admin-Controller hält den verwalteten Key in einer eigenen
    # Instanzvariablen. Hieße sie wie die des authentifizierten Keys, zählte
    # jeder Verwaltungszugriff als Nutzung des bearbeiteten Keys – und beim
    # Löschen liefe die Zählung in den Fremdschlüssel.
    test 'Verwaltungszugriffe zaehlen nicht als Nutzung des Keys' do
      login(@admin)

      assert_no_difference 'ApiKeyUsage.count' do
        patch "/api/v2/admin/api_keys/#{@key.id}", params: { api_key: { rate_limit: 60 } }
        assert_response :success
        get "/api/v2/admin/api_keys/#{@key.id}/usage"
        assert_response :success
      end
    end

    test 'Key mit Antrag laesst sich loeschen' do
      application = create(:api_key_application)
      application.approve!(@admin.id)
      application.reveal_key!

      login(@admin)
      assert_difference 'ApiKey.count', -1 do
        delete "/api/v2/admin/api_keys/#{application.reload.api_key_id}"
      end

      assert_response :no_content
      assert_nil application.reload.api_key_id
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
