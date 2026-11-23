require 'test_helper'

# Schutz der Anmeldung gegen Passwortraten (11/2026). Zwei Ebenen:
#
# - 'login/ip' in config/initializers/rack_attack.rb zaehlt jeden Versuch einer
#   IP, egal ob er gelingt (Password-Spraying, bcrypt-Last).
# - SessionsController (LoginFailureCounter) zaehlt je Benutzername und Netz
#   (10 in 15 Minuten, gezieltes Raten) und je Benutzername allein (50 in
#   einer Stunde, verteiltes Raten aus vielen Netzen).
#
# Den Rack::Attack-Zaehler stellt test_helper.rb pro Test auf null. Die Zaehler
# je Benutzername liegen in Rails.cache, im Test-Env ein :null_store; die Tests
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

  # --- je Benutzername und Netz ------------------------------------------

  ATTACKER_IP = '203.0.113.7'.freeze

  test 'nach zehn Fehlversuchen nimmt das Konto von diesem Netz auch das richtige Passwort nicht an' do
    with_real_cache do
      10.times { login(password: 'falsch') }

      assert_response :unauthorized

      login

      assert_response :too_many_requests
      assert_match 'Passwort vergessen', JSON.parse(response.body)['message']
      assert_nil cookies[:user_id]
    end
  end

  # Der Anlass fuer den Topf je Netz: Eine einzige Adresse konnte bekannte
  # Konten dauerhaft aussperren, weil die Sperre nur am Namen hing.
  test 'gesperrt ist nur das Netz des Angreifers, der Inhaber meldet sich anderswo an' do
    with_real_cache do
      11.times { login(password: 'falsch', ip: ATTACKER_IP) }

      assert_response :too_many_requests

      login(ip: '198.51.100.9')

      assert_response :ok
      assert cookies[:user_id].present?
    end
  end

  test 'IPv6-Adressen aus einem /64 teilen sich den Topf je Netz' do
    with_real_cache do
      10.times { |i| login(password: 'falsch', ip: "2001:db8:1:2::#{i + 1}") }
      login(ip: '2001:db8:1:2:ffff::1')

      assert_response :too_many_requests

      login(ip: '2001:db8:1:3::1')

      assert_response :ok
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

  # --- je Benutzername allein ---------------------------------------------

  def distributed_failures(count, username: @user.user_name)
    count.times { |i| login(username: username, password: 'falsch', ip: "198.51.100.#{i + 1}") }
  end

  test 'nach fuenfzig Versuchen aus verschiedenen Netzen ist das Konto ueberall gesperrt' do
    with_real_cache do
      distributed_failures(LoginFailureCounter::NAME_LIMIT)

      assert_response :unauthorized

      login(ip: '192.0.2.1')

      assert_response :too_many_requests
      assert_nil cookies[:user_id]
    end
  end

  test 'die Sperre je Name gilt eine Stunde' do
    with_real_cache do
      distributed_failures(LoginFailureCounter::NAME_LIMIT)
      travel 16.minutes do
        login(ip: '192.0.2.1')

        assert_response :too_many_requests
      end
      travel 61.minutes do
        login(ip: '192.0.2.2')

        assert_response :ok
      end
    end
  end

  # Abgewiesene Versuche aus einem gesperrten Netz zaehlen nicht in den
  # Namenstopf. Sonst fuellte ein einzelnes Netz ihn ueber 'login/ip' (30 in
  # fuenf Minuten) doch wieder und sperrte das Konto ueberall. Vier volle
  # Fenster zu je zehn ergeben 40, also unter der Grenze.
  test 'ein einzelnes Netz fuellt den Namenstopf nicht' do
    with_real_cache do
      4.times do |round|
        travel(LoginFailureCounter::WINDOW + 1.second) if round.positive?
        15.times { login(password: 'falsch', ip: ATTACKER_IP) }

        assert_response :too_many_requests
      end

      login(ip: '198.51.100.9')

      assert_response :ok
    end
  end

  test 'eine gelungene Anmeldung leert auch den Namenstopf' do
    with_real_cache do
      distributed_failures(LoginFailureCounter::NAME_LIMIT - 1)
      login(ip: '192.0.2.1')

      assert_response :ok
      assert_nil Rails.cache.read(LoginFailureCounter.name_key(@user.user_name), raw: true)

      distributed_failures(LoginFailureCounter::NAME_LIMIT - 1)
      login(ip: '192.0.2.1')

      assert_response :ok
    end
  end

  # --- beide Toepfe --------------------------------------------------------

  # Unbekannte Namen zaehlen genauso, sonst verriete das 429, dass es den
  # Namen gibt. Ebenso wenig darf die Antwort verraten, welcher Topf griff.
  test 'unbekannte und bekannte Namen bekommen dasselbe 429, egal welcher Topf greift' do
    with_real_cache do
      11.times { login(username: 'gibtesnicht', password: 'falsch') }

      assert_response :too_many_requests
      unknown = response.body

      11.times { login(password: 'falsch') }

      assert_response :too_many_requests
      assert_equal unknown, response.body

      distributed_failures(LoginFailureCounter::NAME_LIMIT + 1, username: 'gibtesauchnicht')

      assert_response :too_many_requests
      assert_equal unknown, response.body

      distributed_failures(LoginFailureCounter::NAME_LIMIT + 1)

      assert_response :too_many_requests
      assert_equal unknown, response.body
    end
  end

  # Zaehlen vor bcrypt: Wer am Limit steht, kommt gar nicht erst bis
  # User.login. Mit Lesen, bcrypt und erst danach Hochzaehlen liefen
  # gebuendelte Anfragen alle am selben Zaehlerstand vorbei.
  test 'am Limit je Netz laeuft keine Passwortpruefung mehr' do
    with_real_cache do
      Rails.cache.increment(LoginFailureCounter.key(@user.user_name, ATTACKER_IP), LoginFailureCounter::LIMIT,
                            expires_in: LoginFailureCounter::WINDOW)

      User.stub(:login, ->(*) { flunk 'User.login darf nicht laufen' }) do
        login(ip: ATTACKER_IP)
      end

      assert_response :too_many_requests
    end
  end

  test 'am Limit je Name laeuft keine Passwortpruefung mehr' do
    with_real_cache do
      Rails.cache.increment(LoginFailureCounter.name_key(@user.user_name), LoginFailureCounter::NAME_LIMIT,
                            expires_in: LoginFailureCounter::NAME_WINDOW)

      User.stub(:login, ->(*) { flunk 'User.login darf nicht laufen' }) do
        login(ip: '192.0.2.1')
      end

      assert_response :too_many_requests
    end
  end

  # Die Reihenfolge ist der eigentliche Schutz gegen gebuendelte Anfragen: Steht
  # der Zaehler schon hoch, waehrend bcrypt rechnet, sieht jede parallele
  # Anfrage den eigenen Versuch bereits mitgezaehlt.
  test 'der Versuch ist in beiden Toepfen schon gezaehlt, waehrend das Passwort geprueft wird' do
    with_real_cache do
      net_key = LoginFailureCounter.key(@user.user_name, ATTACKER_IP)
      name_key = LoginFailureCounter.name_key(@user.user_name)
      seen = nil
      User.stub(:login, lambda { |*|
        seen = [Rails.cache.read(net_key, raw: true).to_i, Rails.cache.read(name_key, raw: true).to_i]
        nil
      }) do
        login(password: 'falsch', ip: ATTACKER_IP)
      end

      assert_equal [1, 1], seen
    end
  end

  # Der Versuch, der den Zaehler auf genau LIMIT bringt, ist noch erlaubt; mit
  # dem richtigen Passwort meldet er an und raeumt beide Zaehler ab.
  test 'der letzte erlaubte Versuch meldet mit richtigem Passwort an' do
    with_real_cache do
      key = LoginFailureCounter.key(@user.user_name, ATTACKER_IP)
      Rails.cache.increment(key, LoginFailureCounter::LIMIT - 1, expires_in: LoginFailureCounter::WINDOW)
      login(ip: ATTACKER_IP)

      assert_response :ok
      assert_nil Rails.cache.read(key, raw: true)
      assert_nil Rails.cache.read(LoginFailureCounter.name_key(@user.user_name), raw: true)
    end
  end

  # Die Sperrmeldung verweist auf „Passwort vergessen“. Ein neu gesetztes
  # Passwort muss die Sperre deshalb sofort aufheben, fuer das Netz, von dem
  # aus der Link eingeloest wird.
  def reset_password_via_link(ip:, password: 'NeuesPasswort2026')
    # Seit 2.8.3 nur noch als Digest gespeichert (issue_password_reset_token).
    reset_token = @user.issue_password_reset_token(valid_for: 1.hour)
    @user.save!
    post '/api/v2/reset_password', params: {
      reset_token: reset_token,
      user: { password: password, password_confirmation: password }
    }, as: :json, env: { 'REMOTE_ADDR' => ip }

    assert_response :ok
  end

  test 'ein ueber den Link neu gesetztes Passwort hebt die Sperre je Netz auf' do
    with_real_cache do
      11.times { login(password: 'falsch') }

      assert_response :too_many_requests

      reset_password_via_link(ip: ATTACKER_IP)
      login(password: 'NeuesPasswort2026')

      assert_response :ok
    end
  end

  test 'ein ueber den Link neu gesetztes Passwort hebt die Sperre je Name auf' do
    with_real_cache do
      distributed_failures(LoginFailureCounter::NAME_LIMIT + 1)

      assert_response :too_many_requests

      reset_password_via_link(ip: '192.0.2.1')
      login(password: 'NeuesPasswort2026', ip: '192.0.2.1')

      assert_response :ok
    end
  end

  # Ohne erreichbaren Cache (im Test-Env :null_store) liefert increment nil.
  # Die Grenzen je Benutzername greifen dann nicht, statt alle auszusperren.
  test 'ohne Cache greift die Grenze je Benutzername nicht' do
    15.times { login(password: 'falsch') }
    login

    assert_response :ok
  end
end
