require 'test_helper'

class UserSettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user, language: 'de')
  end

  # Login per POST /api/v2/login, Cookie wird in der Test-Session gehalten
  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  test 'login_hash enthält die Sprache' do
    login_as(@user)
    body = JSON.parse(response.body)
    assert_equal 'de', body.dig('user', 'language')
  end

  test 'Sprache auf en umstellen liefert aktualisierten User zurück' do
    login_as(@user)

    patch '/api/v2/user/language', params: { language: 'en' }, as: :json

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']
    assert_equal 'en', body.dig('user', 'language')
    assert_equal 'en', @user.reload.language
  end

  test 'Ungültige Sprache wird mit 422 abgelehnt' do
    login_as(@user)

    patch '/api/v2/user/language', params: { language: 'fr' }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'de', @user.reload.language
  end

  test 'Sprache ändern ohne Login ergibt 401' do
    patch '/api/v2/user/language', params: { language: 'en' }, as: :json
    assert_response :unauthorized
  end

  test 'Passwort ändern mit korrektem aktuellen Passwort' do
    login_as(@user)

    put '/api/v2/user/password',
        params: { current_password: 'password123', password: 'newsecret1', password_confirmation: 'newsecret1' },
        as: :json

    assert_response :ok
    assert JSON.parse(response.body)['success']
    assert @user.reload.authenticate('newsecret1')
  end

  test 'Passwort ändern mit falschem aktuellen Passwort ergibt 422' do
    login_as(@user)

    put '/api/v2/user/password',
        params: { current_password: 'wrong', password: 'newsecret1', password_confirmation: 'newsecret1' },
        as: :json

    assert_response :unprocessable_entity
    assert @user.reload.authenticate('password123')
  end

  test 'Passwort ändern mit leerem neuen Passwort ergibt 422 und ändert nichts' do
    login_as(@user)

    put '/api/v2/user/password',
        params: { current_password: 'password123', password: '', password_confirmation: '' },
        as: :json

    assert_response :unprocessable_entity
    refute JSON.parse(response.body)['success']
    assert @user.reload.authenticate('password123')
  end

  test 'Passwort ändern mit zu kurzem neuen Passwort ergibt 422 und ändert nichts' do
    login_as(@user)

    put '/api/v2/user/password',
        params: { current_password: 'password123', password: 'short', password_confirmation: 'short' },
        as: :json

    assert_response :unprocessable_entity
    assert @user.reload.authenticate('password123')
  end

  test 'Passwort ändern ohne Login ergibt 401' do
    put '/api/v2/user/password',
        params: { current_password: 'password123', password: 'newsecret1', password_confirmation: 'newsecret1' },
        as: :json
    assert_response :unauthorized
  end

  # --- E-Mail-Änderung mit Bestätigung (Double-Opt-In) ---------------------

  API_KEY = 'test-key-user-settings'.freeze

  def create_api_key
    ApiKey.create!(name: 'Test', key_digest: Digest::SHA256.hexdigest(API_KEY), active: true)
  end

  test 'E-Mail-Änderung anstoßen setzt pending_email und mailt an die neue Adresse' do
    @user.update!(email: 'alt@example.com')
    login_as(@user)

    assert_emails 1 do
      patch '/api/v2/user/email',
            params: { current_password: 'password123', email: 'Neu@Example.com' },
            as: :json
    end

    assert_response :ok
    body = JSON.parse(response.body)
    assert body['success']
    assert_equal 'neu@example.com', body.dig('user', 'pending_email')

    @user.reload
    assert_equal 'alt@example.com', @user.email, 'aktive Adresse darf sich noch nicht ändern'
    assert_equal 'neu@example.com', @user.pending_email
    assert @user.email_confirmation_expires_at > 23.hours.from_now

    mail = ActionMailer::Base.deliveries.last
    assert_equal ['neu@example.com'], mail.to
  end

  test 'E-Mail-Änderung mit falschem Passwort ergibt 422 und verschickt nichts' do
    login_as(@user)

    assert_emails 0 do
      patch '/api/v2/user/email', params: { current_password: 'wrong', email: 'neu@example.com' }, as: :json
    end

    assert_response :unprocessable_entity
    assert_nil @user.reload.pending_email
  end

  test 'E-Mail-Änderung mit ungültiger Adresse ergibt 422' do
    login_as(@user)

    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'kein-mail' }, as: :json

    assert_response :unprocessable_entity
    assert_nil @user.reload.pending_email
  end

  test 'E-Mail-Änderung auf die eigene aktuelle Adresse ergibt 422' do
    @user.update!(email: 'gleich@example.com')
    login_as(@user)

    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'GLEICH@example.com' }, as: :json

    assert_response :unprocessable_entity
  end

  test 'E-Mail-Änderung auf eine bereits vergebene Adresse ergibt 422' do
    create(:user, email: 'vergeben@example.com')
    login_as(@user)

    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'Vergeben@example.com' }, as: :json

    assert_response :unprocessable_entity
    assert_nil @user.reload.pending_email
  end

  test 'E-Mail-Änderung auf eine Adresse mit offener fremder Pending-Änderung ergibt 422' do
    other = create(:user, email: 'other@example.com')
    other.start_email_change!('ziel@example.com')
    login_as(@user)

    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'ziel@example.com' }, as: :json

    assert_response :unprocessable_entity
    assert_nil @user.reload.pending_email
  end

  test 'Abgelaufene fremde Pending-Änderung blockiert die Adresse nicht mehr' do
    other = create(:user, email: 'other@example.com')
    other.start_email_change!('ziel@example.com')
    other.update!(email_confirmation_expires_at: 1.minute.ago)
    login_as(@user)

    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'ziel@example.com' }, as: :json

    assert_response :ok
    assert_equal 'ziel@example.com', @user.reload.pending_email
  end

  test 'Erneutes Anstoßen innerhalb der Wartezeit ergibt 429' do
    login_as(@user)
    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'eins@example.com' }, as: :json
    assert_response :ok

    assert_emails 0 do
      patch '/api/v2/user/email', params: { current_password: 'password123', email: 'zwei@example.com' }, as: :json
    end

    assert_response :too_many_requests
    assert_equal 'eins@example.com', @user.reload.pending_email
  end

  test 'Nach Ablauf der Wartezeit überschreibt erneutes Anstoßen die offene Änderung' do
    login_as(@user)
    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'eins@example.com' }, as: :json
    assert_response :ok
    # Wartezeit künstlich hinter uns lassen (started_at leitet sich aus expires_at ab).
    @user.reload.update!(email_confirmation_expires_at: @user.email_confirmation_expires_at - 2.minutes)
    first_digest = @user.email_confirmation_token_digest

    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'zwei@example.com' }, as: :json

    assert_response :ok
    @user.reload
    assert_equal 'zwei@example.com', @user.pending_email
    refute_equal first_digest, @user.email_confirmation_token_digest, 'alter Token muss ungültig werden'
  end

  test 'Archivierte User können eine offene Änderung nicht mehr bestätigen' do
    create_api_key
    @user.update!(email: 'alt@example.com')
    raw_token = @user.start_email_change!('neu@example.com')
    @user.archive!(@user.id)

    post '/api/v2/user/email/confirm',
         params: { token: raw_token }, headers: { 'X-Api-Key' => API_KEY }, as: :json

    assert_response :not_found
    assert_equal 'alt@example.com', @user.reload.email
  end

  test 'E-Mail-Änderung ohne Login ergibt 401' do
    patch '/api/v2/user/email', params: { current_password: 'password123', email: 'neu@example.com' }, as: :json
    assert_response :unauthorized
  end

  test 'Bestätigung mit gültigem Token übernimmt die neue Adresse' do
    create_api_key
    @user.update!(email: 'alt@example.com')
    raw_token = @user.start_email_change!('neu@example.com')

    post '/api/v2/user/email/confirm',
         params: { token: raw_token }, headers: { 'X-Api-Key' => API_KEY }, as: :json

    assert_response :ok
    assert JSON.parse(response.body)['success']

    @user.reload
    assert_equal 'neu@example.com', @user.email
    assert_nil @user.pending_email
    assert_nil @user.email_confirmation_token_digest
    assert_nil @user.email_confirmation_expires_at
  end

  test 'Bestätigung mit abgelaufenem Token ergibt 404 und ändert nichts' do
    create_api_key
    @user.update!(email: 'alt@example.com')
    raw_token = @user.start_email_change!('neu@example.com')
    @user.update!(email_confirmation_expires_at: 1.minute.ago)

    post '/api/v2/user/email/confirm',
         params: { token: raw_token }, headers: { 'X-Api-Key' => API_KEY }, as: :json

    assert_response :not_found
    assert_equal 'alt@example.com', @user.reload.email
  end

  test 'Bestätigung mit leerem Token ergibt 404 (kein NULL-Match)' do
    create_api_key
    # @user hat kein Token gesetzt – ein leerer Token darf ihn nicht treffen.
    post '/api/v2/user/email/confirm', params: { token: '' }, headers: { 'X-Api-Key' => API_KEY }, as: :json
    assert_response :not_found
  end

  test 'Bestätigung scheitert, wenn die Adresse inzwischen vergeben ist' do
    create_api_key
    @user.update!(email: 'alt@example.com')
    raw_token = @user.start_email_change!('neu@example.com')
    create(:user, email: 'neu@example.com')

    post '/api/v2/user/email/confirm',
         params: { token: raw_token }, headers: { 'X-Api-Key' => API_KEY }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'alt@example.com', @user.reload.email
  end

  test 'Bestätigung ohne Cookie und ohne API-Key ergibt 401' do
    post '/api/v2/user/email/confirm', params: { token: 'egal' }, as: :json
    assert_response :unauthorized
  end
end
