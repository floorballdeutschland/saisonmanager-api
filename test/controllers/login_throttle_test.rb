require 'test_helper'

# Schutz der Anmeldung gegen Passwortraten (11/2026). Zwei Ebenen:
#
# - 'login/ip' in config/initializers/rack_attack.rb zaehlt jeden Versuch einer
#   IP, egal ob er gelingt (Password-Spraying, bcrypt-Last).
# - SessionsController zaehlt die Fehlversuche je Benutzername, unabhaengig von
#   der IP (gezieltes Raten fuer ein Konto mit wechselnden Adressen).
#
# Den Rack::Attack-Zaehler stellt test_helper.rb pro Test auf null. Der Zaehler
# je Benutzername liegt in Rails.cache, im Test-Env ein :null_store; die Tests
# dafuer laufen deshalb in with_real_cache.
class LoginThrottleTest < ActionDispatch::IntegrationTest
  PATH = '/api/v2/login'.freeze

  setup do
    @user = create(:user)
  end

  def login(username: @user.user_name, password: 'password123', path: PATH, ip: '203.0.113.7')
    post path, params: { username: username, password: password }, as: :json,
               env: { 'REMOTE_ADDR' => ip }
  end

  # --- je IP -------------------------------------------------------------

  test 'nach dreissig Versuchen in fuenf Minuten bremst die IP' do
    travel_to Time.zone.now.beginning_of_hour do
      30.times { |i| login(username: "niemand#{i}", password: 'falsch') }

      assert_response :unauthorized

      login

      assert_response :too_many_requests
      assert response.headers['Retry-After'].present?
    end
  end

  test 'eine andere IP wird davon nicht gebremst' do
    travel_to Time.zone.now.beginning_of_hour do
      30.times { |i| login(username: "niemand#{i}", password: 'falsch') }
      login(ip: '198.51.100.9')

      assert_response :ok
    end
  end

  test 'Endung und Schraegstriche umgehen die IP-Grenze nicht' do
    travel_to Time.zone.now.beginning_of_hour do
      10.times { login(path: "#{PATH}.json", username: 'niemand', password: 'falsch') }
      10.times { login(path: '//api/v2/login', username: 'niemand', password: 'falsch') }
      10.times { login(path: "#{PATH}/", username: 'niemand', password: 'falsch') }
      login

      assert_response :too_many_requests
    end
  end

  test 'die alte Route ohne /api/v2 zaehlt mit' do
    travel_to Time.zone.now.beginning_of_hour do
      30.times { login(path: '/login', username: 'niemand', password: 'falsch') }
      login

      assert_response :too_many_requests
    end
  end

  # --- je Benutzername ---------------------------------------------------

  test 'nach zehn Fehlversuchen nimmt das Konto auch das richtige Passwort nicht an' do
    with_real_cache do
      10.times { |i| login(password: 'falsch', ip: "198.51.100.#{i + 1}") }

      assert_response :unauthorized

      login(ip: '198.51.100.99')

      assert_response :too_many_requests
      assert_match 'Passwort vergessen', JSON.parse(response.body)['message']
      assert_nil cookies[:user_id]
    end
  end

  test 'die Sperre endet nach fuenfzehn Minuten' do
    with_real_cache do
      10.times { login(password: 'falsch') }
      travel 16.minutes do
        login

        assert_response :ok
      end
    end
  end

  test 'eine gelungene Anmeldung setzt den Zaehler zurueck' do
    with_real_cache do
      9.times { login(password: 'falsch') }
      login

      assert_response :ok

      9.times { login(password: 'falsch') }
      login

      assert_response :ok
    end
  end

  test 'der Benutzername zaehlt kleinschreibungsneutral' do
    with_real_cache do
      5.times { login(username: @user.user_name.upcase, password: 'falsch') }
      5.times { login(username: @user.user_name, password: 'falsch') }
      login

      assert_response :too_many_requests
    end
  end

  # Ein gesperrtes Konto darf das Nachbarkonto hinter derselben Adresse nicht
  # mitsperren.
  test 'ein anderes Konto bleibt anmeldbar' do
    other = create(:user)
    with_real_cache do
      10.times { login(password: 'falsch') }
      login(username: other.user_name)

      assert_response :ok
    end
  end

  # Unbekannte Namen zaehlen genauso, sonst verriete das 429, dass es den
  # Namen gibt.
  test 'unbekannte Namen werden ebenfalls gesperrt' do
    with_real_cache do
      11.times { login(username: 'gibtesnicht', password: 'falsch') }

      assert_response :too_many_requests
    end
  end
end
