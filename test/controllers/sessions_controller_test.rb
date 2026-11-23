require 'test_helper'

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user, email: 'sammelpostfach@example.com')
  end

  test 'Login per Benutzername setzt die Session' do
    post '/api/v2/login', params: { username: @user.user_name, password: 'password123' }, as: :json

    assert_response :ok
    assert JSON.parse(response.body)['success']
  end

  test 'Login mit der E-Mail-Adresse wird abgelehnt und erklärt den Grund' do
    post '/api/v2/login', params: { username: 'sammelpostfach@example.com', password: 'password123' }, as: :json

    assert_response :unauthorized
    body = JSON.parse(response.body)
    refute body['success']
    assert_includes body['message'], 'Benutzernamen'
  end

  test 'Der E-Mail-Hinweis fällt rein syntaktisch, ohne Datenbanktreffer' do
    # Wichtig: Die Meldung darf nicht verraten, ob die Adresse existiert.
    # Eine im System unbekannte Adresse muss dieselbe Antwort erzeugen.
    post '/api/v2/login', params: { username: 'gibt.es.nicht@example.com', password: 'password123' }, as: :json
    assert_response :unauthorized
    unknown = JSON.parse(response.body)

    post '/api/v2/login', params: { username: 'sammelpostfach@example.com', password: 'falsch' }, as: :json
    assert_response :unauthorized

    assert_equal unknown, JSON.parse(response.body)
  end

  test 'Falscher Benutzername bleibt ohne Hinweistext' do
    post '/api/v2/login', params: { username: 'gibtesnicht', password: 'password123' }, as: :json

    assert_response :unauthorized
    assert_nil JSON.parse(response.body)['message']
  end

  test 'Login ohne Benutzernamen ergibt 401 statt 500' do
    post '/api/v2/login', params: { password: 'password123' }, as: :json

    assert_response :unauthorized
  end

  test 'Passwort vergessen per Benutzername verschickt eine Mail' do
    assert_emails 1 do
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    end

    assert_response :ok
  end

  test 'Passwort vergessen mit der E-Mail-Adresse weist auf den Benutzernamen hin' do
    # Ohne Hinweis liefe die Anfrage ins Leere: Die Suche geht nur über den
    # Benutzernamen, die Antwort ist aber (bewusst) immer success.
    assert_emails 0 do
      post '/api/v2/lost_password', params: { username: 'sammelpostfach@example.com' }, as: :json
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)['message'], 'Benutzernamen'
  end

  test 'Passwort vergessen bleibt bei hängendem SMTP-Server bei 200' do
    # Der Versand läuft synchron im Request; ein Timeout des Mailservers ergab
    # vorher einen 500er (Sentry SAISONMANAGER-1X), obwohl die Antwort dieser
    # Route ohnehin immer gleich lautet.
    failing = Object.new
    def failing.deliver_now
      raise Net::ReadTimeout
    end

    UserMailer.stub(:reset_password, ->(*, **) { failing }) do
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    end

    assert_response :ok
    assert JSON.parse(response.body)['success']
  end

  # Jeder neue Link entwertet den vorigen. Nach einem Doppelklick öffneten
  # Nutzer die erste Mail und scheiterten mit 404 (16./17.11.2026).
  test 'Passwort vergessen kurz hintereinander verschickt nur einen Link, der gültig bleibt' do
    assert_emails 1 do
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    end
    assert_response :ok
    assert JSON.parse(response.body)['success']

    token = ActionMailer::Base.deliveries.last.text_part.decoded[%r{/neues-passwort/([A-Za-z0-9_-]+)}, 1]
    assert token, 'Link fehlt in der Mail'

    post '/api/v2/reset_password',
         params: { reset_token: token, user: { password: 'NeuesPasswort1', password_confirmation: 'NeuesPasswort1' } },
         as: :json
    assert_response :ok
    assert @user.reload.authenticate('NeuesPasswort1')
  end

  test 'Passwort vergessen stellt nach Ablauf der Sperre einen neuen Link aus' do
    post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    first_digest = @user.reload.password_reset_token_digest

    travel(User::PASSWORD_RESET_RESEND_INTERVAL + 1.second) do
      assert_emails 1 do
        post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
      end
    end

    refute_equal first_digest, @user.reload.password_reset_token_digest
  end

  test 'Passwort vergessen nach eingelöstem Link verschickt sofort einen neuen' do
    @user.send_reset_information
    @user.clear_password_reset_token
    @user.save!(validate: false)

    assert_emails 1 do
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    end
  end

  test 'Passwort vergessen nach gescheitertem Versand sperrt das Nachfordern nicht' do
    failing = Object.new
    def failing.deliver_now
      raise Net::ReadTimeout
    end

    UserMailer.stub(:reset_password, ->(*, **) { failing }) do
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    end
    assert_nil @user.reload.password_reset_sent_at

    assert_emails 1 do
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    end
  end

  # Zwei fast gleichzeitige Anfragen in verschiedenen Puma-Workern laden das
  # Konto, bevor eine von beiden den Link ausgestellt hat. Ein echter
  # Wettlauf mit Threads ist im Test nicht verlässlich (alles läuft in einer
  # Transaktion auf einer Verbindung), deshalb stellt der Test den veralteten
  # Stand der zweiten Anfrage direkt her: Ohne Sperre prüft sie ihre eigene,
  # alte Kopie, sieht keinen frischen Link und verschickt einen zweiten.
  test 'Passwort vergessen: zweite Anfrage mit veraltetem Stand stellt keinen zweiten Link aus' do
    first_request = User.find(@user.id)
    second_request = User.find(@user.id)

    assert_emails 1 do
      assert first_request.request_password_reset
      refute second_request.request_password_reset
    end

    assert_equal first_request.password_reset_token_digest, @user.reload.password_reset_token_digest,
                 'der Link der ersten Mail muss gültig bleiben'
  end

  test 'Passwort vergessen hebt die Sperre auch bei einem unerwarteten Mailfehler auf' do
    failing = Object.new
    def failing.deliver_now
      raise ArgumentError, 'kaputte Vorlage'
    end

    UserMailer.stub(:reset_password, ->(*, **) { failing }) do
      assert_raises(ArgumentError) { @user.request_password_reset }
    end
    assert_nil @user.reload.password_reset_sent_at

    assert_emails 1 do
      post '/api/v2/lost_password', params: { username: @user.user_name }, as: :json
    end
  end

  test 'Passwort vergessen für einen unbekannten Benutzernamen bleibt unauffällig' do
    assert_emails 0 do
      post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json
    end

    assert_response :ok
    assert JSON.parse(response.body)['success']
  end

  # --- Benutzername vergessen ------------------------------------------------

  # Die Mail ist multipart (HTML + Text); mail.body ist dann leer, der Inhalt
  # steckt in den Parts. Beide Teile prüfen, damit keiner davon vergessen wird.
  def last_mail_parts
    ActionMailer::Base.deliveries.last.parts.map { |part| part.body.to_s }
  end

  test 'Benutzername vergessen mailt den Kontonamen an die Adresse' do
    assert_emails 1 do
      post '/api/v2/forgot_username', params: { email: 'Sammelpostfach@example.com' }, as: :json
    end

    assert_response :ok
    assert JSON.parse(response.body)['success']

    assert_equal ['sammelpostfach@example.com'], ActionMailer::Base.deliveries.last.to
    parts = last_mail_parts
    assert_equal 2, parts.size, 'HTML- und Text-Teil erwartet'
    parts.each { |part| assert_includes part, @user.user_name }
  end

  test 'Benutzername vergessen listet alle Konten einer Adresse auf' do
    zweites = create(:user, email: 'sammelpostfach@example.com')

    assert_emails 1 do
      post '/api/v2/forgot_username', params: { email: 'sammelpostfach@example.com' }, as: :json
    end

    assert_response :ok
    last_mail_parts.each do |part|
      assert_includes part, @user.user_name
      assert_includes part, zweites.user_name
    end
  end

  test 'Benutzername vergessen sortiert die Namen kleinschreibungsneutral' do
    # Ein blankes ORDER BY folgt der Collation und stellte "Zeta" vor "alpha".
    User.create!(user_name: 'Zeta', password: 'password123', password_confirmation: 'password123',
                 email: 'sortier@example.com', permissions: [], teams: [])
    User.create!(user_name: 'alpha', password: 'password123', password_confirmation: 'password123',
                 email: 'sortier@example.com', permissions: [], teams: [])

    assert_emails 1 do
      post '/api/v2/forgot_username', params: { email: 'sortier@example.com' }, as: :json
    end

    text = last_mail_parts.last
    assert_operator text.index('alpha'), :<, text.index('Zeta')
  end

  test 'Benutzername vergessen wechselt den Betreff in den Plural' do
    assert_emails 1 do
      post '/api/v2/forgot_username', params: { email: 'sammelpostfach@example.com' }, as: :json
    end
    assert_equal 'Dein Benutzername im Saisonmanager', ActionMailer::Base.deliveries.last.subject

    create(:user, email: 'mehrere@example.com')
    create(:user, email: 'mehrere@example.com')

    assert_emails 1 do
      post '/api/v2/forgot_username', params: { email: 'mehrere@example.com' }, as: :json
    end
    assert_equal 'Deine Benutzernamen im Saisonmanager', ActionMailer::Base.deliveries.last.subject
  end

  test 'Benutzername vergessen nennt kein Passwort und keinen Reset-Link' do
    assert_emails 1 do
      post '/api/v2/forgot_username', params: { email: 'sammelpostfach@example.com' }, as: :json
    end

    last_mail_parts.each { |part| refute_includes part, 'neues-passwort/' }
  end

  test 'Benutzername vergessen überspringt archivierte Konten' do
    archiviert = create(:user, email: 'nur-archiv@example.com')
    archiviert.archive!(@user.id)

    assert_emails 0 do
      post '/api/v2/forgot_username', params: { email: 'nur-archiv@example.com' }, as: :json
    end

    assert_response :ok, 'die Antwort bleibt trotzdem unauffällig'
  end

  test 'Benutzername vergessen verrät nicht, ob die Adresse existiert' do
    assert_emails 1 do
      post '/api/v2/forgot_username', params: { email: 'sammelpostfach@example.com' }, as: :json
    end
    assert_response :ok
    bekannt = JSON.parse(response.body)

    assert_emails 0 do
      post '/api/v2/forgot_username', params: { email: 'gibt.es.nicht@example.com' }, as: :json
    end

    assert_response :ok
    assert_equal bekannt, JSON.parse(response.body)
  end

  # Die Wartezeit je Zieladresse hängt am Rails.cache; im Test-Env ist der ein
  # :null_store, in dem nichts liegen bleibt. Für diese beiden Tests daher ein
  # echter Store. Rack::Attack bleibt davon unberührt, es zählt seit #282 in
  # einem eigenen Store aus test_helper.rb.
  def with_memory_cache
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = original
  end

  test 'Benutzername vergessen bremst wiederholte Anfragen zur selben Adresse' do
    with_memory_cache do
      assert_emails 1 do
        post '/api/v2/forgot_username', params: { email: 'sammelpostfach@example.com' }, as: :json
      end

      # Zweite Anfrage innerhalb der Wartezeit: keine Mail, aber weiterhin success
      # (ein sichtbares 429 würde die Adresse verraten).
      assert_emails 0 do
        post '/api/v2/forgot_username', params: { email: 'sammelpostfach@example.com' }, as: :json
      end

      assert_response :ok
      assert JSON.parse(response.body)['success']
    end
  end

  test 'Benutzername vergessen bremst andere Adressen nicht mit' do
    create(:user, email: 'zweite@example.com')

    with_memory_cache do
      assert_emails 1 do
        post '/api/v2/forgot_username', params: { email: 'sammelpostfach@example.com' }, as: :json
      end

      assert_emails 1 do
        post '/api/v2/forgot_username', params: { email: 'zweite@example.com' }, as: :json
      end
    end
  end

  test 'Benutzername vergessen lehnt eine ungültige Adresse mit 422 ab' do
    assert_emails 0 do
      post '/api/v2/forgot_username', params: { email: 'keine-adresse' }, as: :json
    end

    assert_response :unprocessable_entity
    assert JSON.parse(response.body)['message'].present?
  end

  test 'Benutzername vergessen ohne Adresse ergibt 422 statt 500' do
    post '/api/v2/forgot_username', params: {}, as: :json

    assert_response :unprocessable_entity
  end

  # --- IP-Throttle der mail-versendenden Endpunkte ---------------------------
  # Die Wartezeit im Controller greift nur pro Zieladresse. Erst dieser Throttle
  # begrenzt das Gesamtvolumen, also den Fall „Liste fremder Adressen abklappern".
  # Den Zähler stellt test_helper.rb pro Test auf null.
  test 'Benutzername vergessen wird pro IP gedrosselt' do
    10.times do |i|
      post '/api/v2/forgot_username', params: { email: "adresse#{i}@example.com" }, as: :json
      assert_response :ok
    end

    post '/api/v2/forgot_username', params: { email: 'adresse10@example.com' }, as: :json
    assert_response :too_many_requests
    assert JSON.parse(response.body)['error'].present?
  end

  test 'Passwort vergessen fällt unter denselben IP-Throttle' do
    10.times { post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json }

    post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json
    assert_response :too_many_requests
  end

  # Die Routen tragen ein `(.:format)`; der frueher exakte Pfadvergleich liess
  # `…/lost_password.json` ungezaehlt durch.
  test 'Eine angehaengte Endung umgeht den Mail-Throttle nicht' do
    10.times { post '/api/v2/lost_password.json', params: { username: 'gibtesnicht' }, as: :json }

    post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json
    assert_response :too_many_requests
  end

  test 'Doppelte Schraegstriche umgehen den Mail-Throttle nicht' do
    10.times { post '//api/v2/forgot_username', params: { email: 'a@example.com' }, as: :json }

    post '/api/v2/forgot_username', params: { email: 'b@example.com' }, as: :json
    assert_response :too_many_requests
  end

  # Ein Anschluss bekommt ein ganzes IPv6-/64. Jede Adresse daraus einzeln zu
  # zaehlen, gaebe einem Skript beliebig viele Toepfe.
  test 'Wechselnde IPv6-Adressen aus einem /64 teilen sich den Mail-Throttle' do
    10.times do |i|
      post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json,
                                    env: { 'REMOTE_ADDR' => "2001:db8:1:2::#{i + 1}" }
    end

    post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json,
                                  env: { 'REMOTE_ADDR' => '2001:db8:1:2:ffff::1' }
    assert_response :too_many_requests

    post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json,
                                  env: { 'REMOTE_ADDR' => '2001:db8:1:3::1' }
    assert_response :ok
  end

  test 'Der Login selbst wird von diesem Throttle nicht gebremst' do
    12.times do
      post '/api/v2/login', params: { username: @user.user_name, password: 'password123' }, as: :json
      assert_response :ok
    end
  end
end
