require 'test_helper'

# Obergrenze für Crawler auf den öffentlichen Endpunkten
# (config/initializers/rack_attack.rb, Throttle 'crawler/ip').
class CrawlerThrottleTest < ActionDispatch::IntegrationTest
  APPLEBOT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 ' \
             '(KHTML, like Gecko) Version/17.0 Safari/605.1.15 (Applebot/0.1; ' \
             '+http://www.apple.com/go/applebot)'.freeze
  BROWSER = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' \
            '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'.freeze
  # Gerätekennung, die ein pauschales /bot/i fälschlich träfe.
  CUBOT_PHONE = 'Mozilla/5.0 (Linux; Android 13; CUBOT NOTE 40) AppleWebKit/537.36 ' \
                '(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36'.freeze

  setup do
    create(:setting)
  end

  test 'ein Crawler wird nach 60 Aufrufen pro Minute gebremst' do
    with_rack_attack_cache do
      60.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => APPLEBOT } }
      assert_response :success

      get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => APPLEBOT }

      assert_response :too_many_requests
      assert JSON.parse(response.body)['error'].present?
      assert response.headers['Retry-After'].present?
    end
  end

  test 'ein normaler Browser laeuft nicht in den Crawler-Throttle' do
    with_rack_attack_cache do
      70.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => BROWSER } }

      assert_response :success
    end
  end

  test 'eine Gerätekennung mit bot im Namen zaehlt nicht als Crawler' do
    with_rack_attack_cache do
      70.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => CUBOT_PHONE } }

      assert_response :success
    end
  end

  test 'Schreibzugriffe fallen nicht unter den Crawler-Throttle' do
    with_rack_attack_cache do
      # Crawler stellen keine POSTs; ein irrtümlich passendes User-Agent darf
      # deshalb keinen Schreibpfad drosseln.
      70.times do
        post '/api/v2/login', params: { username: 'gibtesnicht', password: 'falsch' },
                              headers: { 'HTTP_USER_AGENT' => APPLEBOT }, as: :json
      end

      assert_response :unauthorized
    end
  end

  private

  # Rack::Attack zählt im Rails.cache, im Test-Env ein :null_store – daher wie in
  # den anderen Throttle-Tests ein echter Store für die Dauer des Tests.
  def with_rack_attack_cache
    original = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rack::Attack.cache.store = original
  end
end
