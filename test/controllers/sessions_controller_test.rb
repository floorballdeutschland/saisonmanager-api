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

  test 'Passwort vergessen für einen unbekannten Benutzernamen bleibt unauffällig' do
    assert_emails 0 do
      post '/api/v2/lost_password', params: { username: 'gibtesnicht' }, as: :json
    end

    assert_response :ok
    assert JSON.parse(response.body)['success']
  end
end
