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

  test 'wechselnde IPv6-Adressen aus einem /64 teilen sich die IP-Grenze' do
    travel_to Time.zone.now.beginning_of_hour do
      30.times { |i| login(username: "niemand#{i}", password: 'falsch', ip: "2001:db8:1:2::#{i + 1}") }
      login(ip: '2001:db8:1:2:ffff::1')

      assert_response :too_many_requests

      login(ip: '2001:db8:1:3::1')

      assert_response :ok
    end
  end

  test 'das 429 der IP-Grenze verweist auf Passwort vergessen' do
    travel_to Time.zone.now.beginning_of_hour do
      31.times { login(password: 'falsch') }

      assert_response :too_many_requests
      assert_match 'Passwort vergessen', JSON.parse(response.body)['message']
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
      11.times { |i| login(username: 'gibtesnicht', password: 'falsch', ip: "198.51.100.#{i + 1}") }

      assert_response :too_many_requests
      unknown = response.body

      11.times { |i| login(password: 'falsch', ip: "198.51.100.#{i + 101}") }

      assert_response :too_many_requests
      assert_equal unknown, response.body
    end
  end

  # Zaehlen vor bcrypt: Wer am Limit steht, kommt gar nicht erst bis
  # User.login. Mit Lesen, bcrypt und erst danach Hochzaehlen liefen
  # gebuendelte Anfragen alle am selben Zaehlerstand vorbei.
  test 'am Limit laeuft keine Passwortpruefung mehr' do
    with_real_cache do
      Rails.cache.increment(LoginFailureCounter.key(@user.user_name), LoginFailureCounter::LIMIT,
                            expires_in: LoginFailureCounter::WINDOW)

      User.stub(:login, ->(*) { flunk 'User.login darf nicht laufen' }) do
        login
      end

      assert_response :too_many_requests
    end
  end

  # Die Reihenfolge ist der eigentliche Schutz gegen gebuendelte Anfragen: Steht
  # der Zaehler schon hoch, waehrend bcrypt rechnet, sieht jede parallele
  # Anfrage den eigenen Versuch bereits mitgezaehlt.
  test 'der Versuch ist schon gezaehlt, waehrend das Passwort geprueft wird' do
    with_real_cache do
      key = LoginFailureCounter.key(@user.user_name)
      seen = nil
      User.stub(:login, lambda { |*|
        seen = Rails.cache.read(key, raw: true).to_i
        nil
      }) do
        login(password: 'falsch')
      end

      assert_equal 1, seen
    end
  end

  # Der Versuch, der den Zaehler auf genau LIMIT bringt, ist noch erlaubt; mit
  # dem richtigen Passwort meldet er an und raeumt den Zaehler ab.
  test 'der letzte erlaubte Versuch meldet mit richtigem Passwort an' do
    with_real_cache do
      key = LoginFailureCounter.key(@user.user_name)
      Rails.cache.increment(key, LoginFailureCounter::LIMIT - 1, expires_in: LoginFailureCounter::WINDOW)
      login

      assert_response :ok
      assert_nil Rails.cache.read(key, raw: true)
    end
  end

  # Die Sperrmeldung verweist auf „Passwort vergessen“. Ein neu gesetztes
  # Passwort muss die Sperre deshalb sofort aufheben.
  test 'ein ueber den Link neu gesetztes Passwort hebt die Sperre auf' do
    # Seit 2.8.3 nur noch als Digest gespeichert (issue_password_reset_token).
    reset_token = @user.issue_password_reset_token(valid_for: 1.hour)
    @user.save!
    with_real_cache do
      11.times { login(password: 'falsch') }

      assert_response :too_many_requests

      post '/api/v2/reset_password', params: {
        reset_token: reset_token,
        user: { password: 'NeuesPasswort2026', password_confirmation: 'NeuesPasswort2026' }
      }, as: :json

      assert_response :ok

      login(password: 'NeuesPasswort2026')

      assert_response :ok
    end
  end

  # Ohne erreichbaren Cache (im Test-Env :null_store) liefert increment nil.
  # Die Grenze je Benutzername greift dann nicht, statt alle auszusperren.
  test 'ohne Cache greift die Grenze je Benutzername nicht' do
    15.times { |i| login(password: 'falsch', ip: "198.51.100.#{i + 1}") }
    login(ip: '198.51.100.99')

    assert_response :ok
  end
end
