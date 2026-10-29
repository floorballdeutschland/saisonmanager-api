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
