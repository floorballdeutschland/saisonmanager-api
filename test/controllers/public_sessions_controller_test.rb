require 'test_helper'

# Anonyme Website-Sitzung als dritter Weg in authenticate_public_request, neben
# Anmeldung und API-Key (PublicSession, ersetzt den Frontend-Key im Bundle).
class PublicSessionsControllerTest < ActionDispatch::IntegrationTest
  PUBLIC_PATH = '/api/v2/game_operations'.freeze

  setup do
    create(:setting)
  end

  test 'ohne Key und ohne Sitzung kommt ein 401 mit Hinweis fuer das Frontend' do
    get PUBLIC_PATH

    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal 'public_session_required', body['code']
    assert_equal 'API key required', body['message'], 'Fremde Integrationen lesen weiter die alte Meldung'
  end

  test 'mit einer ausgestellten Sitzung ist der oeffentliche Abruf erlaubt' do
    post '/api/v2/public_session'
    assert_response :success
    assert cookies[PublicSession::COOKIE_NAME].present?

    get PUBLIC_PATH

    assert_response :success
  end

  test 'das Cookie ist httponly und SameSite=Strict' do
    post '/api/v2/public_session'

    set_cookie = Array(response.headers['Set-Cookie']).join("\n")
    line = set_cookie.lines.find { |l| l.start_with?("#{PublicSession::COOKIE_NAME}=") }
    assert line, 'Sitzungs-Cookie fehlt'
    assert_match(/httponly/i, line)
    assert_match(/samesite=strict/i, line)
  end

  test 'ein erneuter Aufruf fuehrt die Sitzung mit derselben Kennung weiter' do
    post '/api/v2/public_session'
    first = PublicSession.verify(cookies[PublicSession::COOKIE_NAME])

    post '/api/v2/public_session'
    second = PublicSession.verify(cookies[PublicSession::COOKIE_NAME])

    assert_equal first.id, second.id
  end

  test 'eine gefaelschte Sitzung wird abgewiesen' do
    cookies[PublicSession::COOKIE_NAME] = 'frei-erfunden'

    get PUBLIC_PATH

    assert_response :unauthorized
  end

  test 'eine abgelaufene Sitzung wird abgewiesen' do
    post '/api/v2/public_session'

    travel PublicSession::TTL + 1.minute do
      get PUBLIC_PATH

      assert_response :unauthorized
      assert_equal 'public_session_required', JSON.parse(response.body)['code']
    end
  end

  test 'nach der halben Laufzeit wird das Cookie still erneuert' do
    post '/api/v2/public_session'
    original = PublicSession.verify(cookies[PublicSession::COOKIE_NAME])

    travel PublicSession::RENEW_AFTER + 1.minute do
      get PUBLIC_PATH
      assert_response :success

      renewed = PublicSession.verify(cookies[PublicSession::COOKIE_NAME])
      assert_equal original.id, renewed.id
      assert renewed.issued_at > original.issued_at
    end

    # Ohne die Erneuerung wäre die Sitzung hier abgelaufen.
    travel PublicSession::TTL + 1.hour do
      get PUBLIC_PATH

      assert_response :success
    end
  end

  test 'Zugriffe ueber die Sitzung landen im eigenen Zaehler, nicht bei einem Key' do
    post '/api/v2/public_session'

    assert_difference -> { PublicSessionUsage.sum(:count) }, 2 do
      2.times { get PUBLIC_PATH }
    end
    assert_equal 0, ApiKeyUsage.count
    assert_equal 'game_operations#index', PublicSessionUsage.last.endpoint
  end

  test 'ein Key hat Vorrang und wird weiter bei sich gezaehlt' do
    raw_key, api_key = ApiKey.generate(name: 'Integration')
    post '/api/v2/public_session'

    get PUBLIC_PATH, headers: { 'HTTP_X_API_KEY' => raw_key }

    assert_response :success
    assert_equal 1, api_key.api_key_usages.sum(:count)
    assert_equal 0, PublicSessionUsage.count
  end

  # Ohne diese Zeile laesst sich im Log nicht sagen, welcher Server mit
  # welchem Key abruft: Die Statistik kennt keine Adressen.
  test 'jeder Zugriff ueber Key oder Sitzung steht mit Weg und Adresse im Log' do
    raw_key, api_key = ApiKey.generate(name: 'Integration')

    log = capture_log do
      get PUBLIC_PATH, headers: { 'HTTP_X_API_KEY' => raw_key }
      post '/api/v2/public_session'
      get PUBLIC_PATH
    end

    assert_match(/public-access api_key=#{api_key.id} ip=127\.0\.0\.1 endpoint=game_operations#index/, log)
    session_prefix = PublicSession.verify(cookies[PublicSession::COOKIE_NAME]).id.first(8)
    assert_match(/public-access public_session=#{session_prefix} ip=127\.0\.0\.1 endpoint=game_operations#index/, log)
  end

  # Der fruehere Frontend-Key wird von fremden Seiten weiterbenutzt; erkennen
  # lassen sie sich nur an diesen Kopfzeilen.
  test 'ein Key-Zugriff steht mit Origin, Referer und User-Agent im Log' do
    raw_key, api_key = ApiKey.generate(name: 'Integration')

    log = capture_log do
      get PUBLIC_PATH, headers: {
        'HTTP_X_API_KEY' => raw_key,
        'HTTP_ORIGIN' => 'https://verein.example',
        'HTTP_REFERER' => 'https://verein.example/spielplan?token=geheim#tabelle',
        'HTTP_USER_AGENT' => "Widget/1.0 #{'x' * 300}"
      }
    end

    line = log.lines.grep(/public-access api_key=#{api_key.id} /).first
    assert line, 'keine public-access-Zeile fuer den Key'
    refute_includes line, 'geheim'
    assert_includes line, 'origin="https://verein.example" referer="https://verein.example/spielplan"'
    assert_match(%r{ua="Widget/1\.0 x{189}"$}, line.chomp)
  end

  test 'fehlende Kopfzeilen stehen als Strich im Log, Sitzungen ohne Herkunft' do
    raw_key, api_key = ApiKey.generate(name: 'Integration')

    log = capture_log do
      get PUBLIC_PATH, headers: { 'HTTP_X_API_KEY' => raw_key, 'HTTP_USER_AGENT' => '' }
      post '/api/v2/public_session'
      get PUBLIC_PATH, headers: { 'HTTP_REFERER' => 'https://saisonmanager.de/' }
    end

    assert_match(/public-access api_key=#{api_key.id} .* origin=- referer=- ua=-$/, log)
    session_line = log.lines.grep(/public-access public_session=/).first
    assert session_line, 'keine public-access-Zeile fuer die Sitzung'
    assert_no_match(/referer|origin|ua=/, session_line)
  end

  test 'Steuerzeichen und Anfuehrungszeichen in Kopfzeilen sprengen die Logzeile nicht' do
    raw_key, = ApiKey.generate(name: 'Integration')

    log = capture_log do
      get PUBLIC_PATH, headers: { 'HTTP_X_API_KEY' => raw_key, 'HTTP_USER_AGENT' => "a\"b\tc\xFF".b * 100 }
    end

    line = log.lines.grep(/public-access api_key=/).first
    assert line, 'keine public-access-Zeile fuer den Key'
    assert_match(/ua="(a\?b\?c\?){33}a\?"$/, line.chomp)
  end

  test 'angemeldete Zugriffe erscheinen nicht als oeffentlicher Zugriff im Log' do
    user = create(:user, :admin)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }

    log = capture_log { get PUBLIC_PATH }

    assert_response :success
    assert_no_match(/public-access/, log)
  end

  test 'angemeldete Nutzer werden nicht als anonyme Besucher gezaehlt' do
    user = create(:user, :admin, password: 'password123')
    post '/api/v2/public_session'
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success

    get PUBLIC_PATH

    assert_response :success
    assert_equal 0, PublicSessionUsage.count
  end

  private

  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
