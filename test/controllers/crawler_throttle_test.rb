require 'test_helper'

# Obergrenze für Crawler auf den öffentlichen Endpunkten
# (config/initializers/rack_attack.rb, Throttle 'crawler/ip').
#
# Den Cache-Store stellt test_helper.rb bereit und leert ihn vor jedem Test;
# ein eigener Store je Test wäre genau die Doppelung, die api#290 aufgelöst hat.
#
# Gezählt wird in einem festen Minutenfenster (epoch / period), nicht gleitend.
# Ohne travel_to fällt ein Lauf, der zufällig über eine Minutengrenze reicht,
# in ein neues Fenster, und der 61. Aufruf käme durch – ein Flake, dessen
# Häufigkeit mit der Laufzeit steigt.
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
    travel_to Time.zone.now.beginning_of_minute do
      60.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => APPLEBOT } }
      assert_response :success

      get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => APPLEBOT }

      assert_response :too_many_requests
      assert JSON.parse(response.body)['error'].present?
      assert response.headers['Retry-After'].present?
    end
  end

  test 'ein normaler Browser laeuft nicht in den Crawler-Throttle' do
    travel_to Time.zone.now.beginning_of_minute do
      70.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => BROWSER } }

      assert_response :success
    end
  end

  test 'eine Gerätekennung mit bot im Namen zaehlt nicht als Crawler' do
    travel_to Time.zone.now.beginning_of_minute do
      70.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => CUBOT_PHONE } }

      assert_response :success
    end
  end

  # HEAD kostet den Server dasselbe wie GET. Link-Prüfer und einige Crawler
  # holen ausschließlich Header, das darf keine Lücke sein.
  test 'HEAD-Aufrufe zaehlen mit' do
    travel_to Time.zone.now.beginning_of_minute do
      60.times { head '/api/v2/version', headers: { 'HTTP_USER_AGENT' => APPLEBOT } }
      assert_response :success

      head '/api/v2/version', headers: { 'HTTP_USER_AGENT' => APPLEBOT }

      assert_response :too_many_requests
    end
  end

  # Wer angemeldet ist, soll sich nicht an einer falsch erkannten Kennung
  # ausbremsen. Geprüft wird nur, ob ein user_id-Cookie anliegt.
  test 'eine angemeldete Sitzung faellt nicht unter den Throttle' do
    user = create(:user, :admin)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success

    travel_to Time.zone.now.beginning_of_minute do
      70.times { get '/api/v2/version', headers: { 'HTTP_USER_AGENT' => APPLEBOT } }

      assert_response :success
    end
  end

  test 'Schreibzugriffe fallen nicht unter den Crawler-Throttle' do
    travel_to Time.zone.now.beginning_of_minute do
      # Crawler stellen keine POSTs; ein irrtümlich passendes User-Agent darf
      # deshalb keinen Schreibpfad drosseln.
      70.times do
        post '/api/v2/login', params: { username: 'gibtesnicht', password: 'falsch' },
                              headers: { 'HTTP_USER_AGENT' => APPLEBOT }, as: :json
      end

      assert_response :unauthorized
    end
  end

  # Der `Forwarded`-Header darf req.ip nicht mehr bestimmen. Sonst liesse sich
  # jede Drosselung pro IP mit einem Header abschalten, auch die gegen
  # Mail-Fluten und gegen das Durchprobieren von Einmal-Links.
  test 'ein mitgeschickter Forwarded-Header verschiebt den Zaehler nicht' do
    travel_to Time.zone.now.beginning_of_minute do
      61.times do |i|
        get '/api/v2/version', headers: {
          'HTTP_USER_AGENT' => APPLEBOT,
          'HTTP_FORWARDED' => "for=203.0.113.#{i}"
        }
      end

      assert_response :too_many_requests
    end
  end
end
