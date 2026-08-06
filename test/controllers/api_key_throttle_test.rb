require 'test_helper'

# Grenze je API-Key (config/initializers/rack_attack.rb, Throttle 'api/key').
#
# Bis beantragte Zugänge eine Grenze mitbekamen, hatte kein Key im Betrieb eine:
# Der Throttle hat nie ausgelöst, und dass sein 429 zeitweise ein 500 war, fiel
# erst über den Test eines anderen Throttles auf (Kommentar im Initializer).
# Deshalb hier der Pfad, den die Vereinbarung zusagt, End-to-End.
#
# Aufbau wie CrawlerThrottleTest: fester Cache-Store aus dem test_helper, und
# travel_to auf den Minutenanfang, weil in einem festen Fenster gezählt wird.
# `/api/v2/version` ist offen; gedrosselt wird allein anhand des mitgeschickten
# Keys, der Endpunkt ist also nur ein billiger Aufhänger.
class ApiKeyThrottleTest < ActionDispatch::IntegrationTest
  # Kennung, mit der Integrationen typischerweise gebaut werden. Sie steht in
  # CRAWLER_USER_AGENTS und ist damit der Fall, an dem sich Key- und IP-Topf
  # sonst überlagern.
  SCRIPT_CLIENT = 'python-requests/2.32.3'.freeze

  setup do
    create(:setting)
  end

  test 'ein Key mit Grenze wird nach Erreichen gedrosselt' do
    raw_key, = ApiKey.generate(name: 'Testzugang', rate_limit: 5)

    travel_to Time.zone.now.beginning_of_minute do
      5.times { get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key } }
      assert_response :success

      get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key }

      assert_response :too_many_requests
      assert JSON.parse(response.body)['error'].present?
      assert response.headers['Retry-After'].present?, 'Ohne Retry-After weiß der Client nicht, wie lange'
    end
  end

  # nil heißt unbegrenzt: der Key des eigenen Frontends und der des
  # Prerender-Builds dürfen sich nicht selbst ausbremsen.
  test 'ein Key ohne Grenze bleibt ungedrosselt' do
    raw_key, = ApiKey.generate(name: 'Frontend')

    travel_to Time.zone.now.beginning_of_minute do
      70.times { get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key } }

      assert_response :success
    end
  end

  test 'ein beantragter Zugang bekommt genau die Grenze aus der Vereinbarung' do
    application = create(:api_key_application)
    application.approve!(1)
    raw_key = application.reveal_key!

    travel_to Time.zone.now.beginning_of_minute do
      ApiTerms::RATE_LIMIT_PER_MINUTE.times { get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key } }
      assert_response :success

      get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key }

      assert_response :too_many_requests
    end
  end

  # Sonst hinge ein beantragter Zugang an zwei Grenzen: 60 je Key hier und
  # zusätzlich 60 je IP im Crawler-Topf, weil seine Kennung dort passt. Ein
  # Anheben des Key-Limits durch die Verwaltung bliebe dann wirkungslos.
  test 'ein Key mit eigener Grenze faellt nicht zusaetzlich in den Crawler-Topf' do
    raw_key, = ApiKey.generate(name: 'Integration', rate_limit: 200)

    travel_to Time.zone.now.beginning_of_minute do
      70.times do
        get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key, 'HTTP_USER_AGENT' => SCRIPT_CLIENT }
      end

      assert_response :success
    end
  end

  # Die Kehrseite: Der Frontend-Key steht im ausgelieferten Bundle. Wäre jeder
  # gültige Key von der Crawler-Bremse ausgenommen, wäre er der bequemste Weg,
  # sie abzuschalten.
  test 'ein Key ohne eigene Grenze bleibt im Crawler-Topf' do
    raw_key, = ApiKey.generate(name: 'Frontend')

    travel_to Time.zone.now.beginning_of_minute do
      60.times do
        get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key, 'HTTP_USER_AGENT' => SCRIPT_CLIENT }
      end
      assert_response :success

      get '/api/v2/version', headers: { 'HTTP_X_API_KEY' => raw_key, 'HTTP_USER_AGENT' => SCRIPT_CLIENT }

      assert_response :too_many_requests
    end
  end
end
