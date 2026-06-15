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
end
