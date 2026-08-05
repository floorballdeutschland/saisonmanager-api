require 'test_helper'

class ApiKeyApplicationsControllerTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze # test/fixtures/api_keys.yml
  HEADERS = { 'X-Api-Key' => API_KEY }.freeze

  setup { create(:setting) }

  test 'gueltiger Antrag wird angelegt und meldet den Eingang' do
    assert_enqueued_emails 1 do
      post '/api/v2/api_key_applications', params: { api_key_application: valid_params }, headers: HEADERS
    end

    assert_response :created
    application = ApiKeyApplication.order(:id).last
    assert_equal 'pending', application.status
    assert_equal 'antrag@example.com', application.email
    assert application.accepted_terms_at.present?
    assert application.accepted_terms_ip.present?, 'Die IP wird serverseitig festgehalten'
  end

  test 'ohne Zustimmung kein Antrag' do
    assert_no_difference 'ApiKeyApplication.count' do
      post '/api/v2/api_key_applications',
           params: { api_key_application: valid_params(accept_terms: false) }, headers: HEADERS
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)['errors'].join(' '), 'Nutzungsvereinbarung'
  end

  test 'kommerzielles Vorhaben endet mit Verweis auf das Postfach' do
    assert_no_difference 'ApiKeyApplication.count' do
      assert_no_enqueued_emails do
        post '/api/v2/api_key_applications',
             params: { api_key_application: valid_params(commercial: true) }, headers: HEADERS
      end
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)['errors'].join(' '), 'it@floorball.de'
  end

  test 'veraltete Fassung der Bedingungen wird abgewiesen' do
    assert_no_difference 'ApiKeyApplication.count' do
      post '/api/v2/api_key_applications',
           params: { api_key_application: valid_params(terms_version: '2020-01-01') }, headers: HEADERS
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)['errors'].join(' '), 'aktualisiert'
  end

  test 'unvollstaendiger Antrag nennt die fehlenden Felder' do
    post '/api/v2/api_key_applications',
         params: { api_key_application: valid_params(organisation: '') }, headers: HEADERS

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)['errors'].any?
  end

  test 'ohne API-Key kein Antrag' do
    post '/api/v2/api_key_applications', params: { api_key_application: valid_params }

    assert_response :unauthorized
  end

  test 'Fassung der Bedingungen ist abrufbar' do
    get '/api/v2/api_terms_version', headers: HEADERS

    assert_response :success
    assert_equal ApiTerms::VERSION, JSON.parse(response.body)['version']
  end

  test 'Abhol-Link zeigt den Zustand ohne ihn zu verbrauchen' do
    application = create(:api_key_application)
    token = application.approve!(1)

    2.times do
      get "/api/v2/api_key_applications/reveal/#{token}", headers: HEADERS
      assert_response :success
      assert_equal 'valid', JSON.parse(response.body)['state']
    end

    assert_nil application.reload.key_revealed_at
  end

  test 'Abholen liefert den Key genau einmal' do
    application = create(:api_key_application)
    token = application.approve!(1)

    post '/api/v2/api_key_applications/reveal', params: { token: token }, headers: HEADERS

    assert_response :success
    body = JSON.parse(response.body)
    assert body['raw_key'].present?
    assert_equal Digest::SHA256.hexdigest(body['raw_key']), application.reload.api_key.key_digest

    post '/api/v2/api_key_applications/reveal', params: { token: token }, headers: HEADERS
    assert_response :gone
  end

  test 'unbekanntes Token verraet nichts' do
    get '/api/v2/api_key_applications/reveal/unbekannt', headers: HEADERS
    assert_response :gone

    post '/api/v2/api_key_applications/reveal', params: { token: 'unbekannt' }, headers: HEADERS
    assert_response :gone
  end

  test 'zu viele Antraege je IP werden gedrosselt' do
    # Fester Zeitpunkt: Der Throttle rechnet in festen Fenstern, ein Lauf über
    # eine Fenstergrenze hinweg wäre sonst vom Zufall abhängig.
    travel_to Time.zone.now.beginning_of_hour do
      10.times do
        post '/api/v2/api_key_applications',
             params: { api_key_application: valid_params(accept_terms: false) }, headers: HEADERS
        assert_response :unprocessable_entity
      end

      post '/api/v2/api_key_applications',
           params: { api_key_application: valid_params(accept_terms: false) }, headers: HEADERS
      assert_response :too_many_requests
      assert response.headers['Retry-After'].present?
    end
  end

  # Der Abhol-Link hat einen eigenen Topf. Sonst sperrte sich ein Antragsteller,
  # der zehnmal etwas abgeschickt hat, vom eigenen Schlüssel aus – und der lässt
  # sich nur ein einziges Mal abholen.
  test 'ausgeschoepftes Antrags-Limit sperrt das Abholen nicht' do
    application = create(:api_key_application)
    token = application.approve!(1)

    travel_to Time.zone.now.beginning_of_hour do
      11.times do
        post '/api/v2/api_key_applications',
             params: { api_key_application: valid_params(accept_terms: false) }, headers: HEADERS
      end
      assert_response :too_many_requests

      get "/api/v2/api_key_applications/reveal/#{token}", headers: HEADERS
      assert_response :success

      post '/api/v2/api_key_applications/reveal', params: { token: token }, headers: HEADERS
      assert_response :success
    end
  end

  test 'Zugriffe mit API-Key werden pro Endpunkt gezaehlt' do
    key = ApiKey.find_by(key_digest: Digest::SHA256.hexdigest(API_KEY))

    assert_difference -> { ApiKeyUsage.where(api_key_id: key.id).sum(:count) }, 2 do
      2.times { get '/api/v2/api_terms_version', headers: HEADERS }
    end

    usage = ApiKeyUsage.find_by(api_key_id: key.id, endpoint: 'api_key_applications#terms_version')
    assert_equal 2, usage.count
  end

  test 'abgewiesene Zugriffe ohne Key werden nicht gezaehlt' do
    assert_no_difference 'ApiKeyUsage.count' do
      get '/api/v2/api_terms_version'
    end

    assert_response :unauthorized
  end

  private

  def valid_params(overrides = {})
    {
      accept_terms: true,
      commercial: false,
      organisation: 'Floorball Beispielstadt',
      contact_name: 'Test Person',
      email: 'antrag@example.com',
      address: 'Beispielweg 1, 12345 Beispielstadt',
      project_description: 'Widget mit Spielplan und Tabelle für die Vereinswebsite.',
      purpose: 'Einbindung auf der eigenen Website.',
      project_url: 'https://example.com/floorball',
      terms_version: ApiTerms::VERSION
    }.merge(overrides)
  end
end
