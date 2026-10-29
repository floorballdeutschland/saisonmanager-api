require 'test_helper'

# Drosseln der anonymen Website-Sitzungen (config/initializers/rack_attack.rb,
# 'public-session/ip' und 'public-session/id'). Aufbau wie CrawlerThrottleTest:
# fester Cache-Store aus dem test_helper, travel_to auf den Minutenanfang.
#
# Das POST, das die Sitzung ausstellt, traegt selbst noch kein Cookie und
# zaehlt daher nicht in den Topf der Sitzung.
class PublicSessionThrottleTest < ActionDispatch::IntegrationTest
  PUBLIC_PATH = '/api/v2/game_operations'.freeze

  setup do
    create(:setting)
  end

  test 'eine Sitzung wird nach Erreichen ihrer Grenze gedrosselt' do
    travel_to Time.zone.now.beginning_of_minute do
      post '/api/v2/public_session'
      PublicSession::RATE_LIMIT_PER_MINUTE.times { get PUBLIC_PATH }
      assert_response :success

      get PUBLIC_PATH

      assert_response :too_many_requests
    end
  end

  # Der Fall in der Halle: viele Besucher, eine Adresse. Die Grenze gilt je
  # Sitzung, ein zweiter Besucher bleibt vom ersten unberuehrt.
  test 'Sitzungen hinter derselben Adresse bremsen sich nicht gegenseitig' do
    travel_to Time.zone.now.beginning_of_minute do
      post '/api/v2/public_session'
      PublicSession::RATE_LIMIT_PER_MINUTE.times { get PUBLIC_PATH }
      get PUBLIC_PATH
      assert_response :too_many_requests

      cookies.delete(PublicSession::COOKIE_NAME)
      post '/api/v2/public_session'
      get PUBLIC_PATH

      assert_response :success
    end
  end

  test 'das Ausstellen wird je Adresse begrenzt' do
    travel_to Time.zone.now.beginning_of_minute do
      PublicSession::ISSUE_LIMIT_PER_MINUTE.times do
        cookies.delete(PublicSession::COOKIE_NAME)
        post '/api/v2/public_session'
      end
      assert_response :success

      cookies.delete(PublicSession::COOKIE_NAME)
      post '/api/v2/public_session.json'

      assert_response :too_many_requests
    end
  end

  # Wer laufend frische Sitzungen holt, um die Grenze je Sitzung zu umgehen,
  # stoesst an den Stundentopf, auch wenn er die Minutengrenze einhaelt.
  test 'das Ausstellen wird zusaetzlich je Stunde begrenzt' do
    start = Time.zone.now.beginning_of_hour
    issued = 0
    (PublicSession::ISSUE_LIMIT_PER_HOUR / PublicSession::ISSUE_LIMIT_PER_MINUTE).times do |minute|
      travel_to start + minute.minutes do
        PublicSession::ISSUE_LIMIT_PER_MINUTE.times do
          cookies.delete(PublicSession::COOKIE_NAME)
          post '/api/v2/public_session'
          issued += 1 if response.successful?
        end
      end
    end
    rest = PublicSession::ISSUE_LIMIT_PER_HOUR - issued

    travel_to start + 30.minutes do
      rest.times do
        cookies.delete(PublicSession::COOKIE_NAME)
        post '/api/v2/public_session'
      end
      assert_response :success

      cookies.delete(PublicSession::COOKIE_NAME)
      post '/api/v2/public_session'

      assert_response :too_many_requests
    end
  end

  # Der Controller nimmt einen ungueltigen Key nicht an und laesst den Request
  # ueber die Sitzung laufen. Dann muss er auch in deren Topf zaehlen.
  test 'ein erfundener API-Key umgeht die Sitzungsgrenze nicht' do
    travel_to Time.zone.now.beginning_of_minute do
      post '/api/v2/public_session'
      headers = { 'HTTP_X_API_KEY' => 'quatsch' }
      PublicSession::RATE_LIMIT_PER_MINUTE.times { get PUBLIC_PATH, headers: headers }
      assert_response :success

      get PUBLIC_PATH, headers: headers

      assert_response :too_many_requests
    end
  end

  test 'mit gueltigem Key laeuft man nicht in die Sitzungsgrenze' do
    raw_key, = ApiKey.generate(name: 'Partner')
    travel_to Time.zone.now.beginning_of_minute do
      post '/api/v2/public_session'
      (PublicSession::RATE_LIMIT_PER_MINUTE + 1).times do
        get PUBLIC_PATH, headers: { 'HTTP_X_API_KEY' => raw_key }
      end

      assert_response :success
    end
  end

  # Ein erfundenes user_id-Cookie macht niemanden zum angemeldeten Nutzer. Der
  # Controller nimmt den Request dann ueber die Sitzung an, also muss sie auch
  # gezaehlt werden.
  test 'ein gefaelschtes Anmelde-Cookie umgeht die Grenze nicht' do
    travel_to Time.zone.now.beginning_of_minute do
      post '/api/v2/public_session'
      cookies['user_id'] = '1'
      PublicSession::RATE_LIMIT_PER_MINUTE.times { get PUBLIC_PATH }
      assert_response :success

      get PUBLIC_PATH

      assert_response :too_many_requests
    end
  end

  test 'angemeldete Nutzer laufen nicht in die Sitzungsgrenze' do
    user = create(:user, :admin)
    travel_to Time.zone.now.beginning_of_minute do
      post '/api/v2/public_session'
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success

      PublicSession::RATE_LIMIT_PER_MINUTE.times { get PUBLIC_PATH }

      assert_response :success
    end
  end
end
