require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    @user.update_column(:password_reset_token, SecureRandom.uuid)
  end

  def reset_password(password)
    post '/api/v2/reset_password',
         params: { reset_token: @user.password_reset_token,
                   user: { password: password, password_confirmation: password } },
         as: :json
  end

  test 'neues Passwort nach den Regeln wird gesetzt und verbraucht das Token' do
    reset_password('NeuesGeheim1234')

    assert_response :ok
    assert @user.reload.authenticate('NeuesGeheim1234')
    assert_nil @user.password_reset_token
  end

  test 'zu kurzes Passwort wird abgelehnt und das Token bleibt gültig' do
    reset_password('Geheim12345')

    assert_response :unprocessable_entity
    assert_equal PasswordPolicy::REQUIREMENTS, JSON.parse(response.body)['message']
    assert @user.reload.authenticate('password123')
    assert_not_nil @user.password_reset_token
  end

  test 'Passwort ohne Großbuchstaben wird abgelehnt' do
    reset_password('neuesgeheim1234')

    assert_response :unprocessable_entity
    assert @user.reload.authenticate('password123')
  end

  test 'Passwort ohne Ziffer wird abgelehnt' do
    reset_password('NeuesGeheimwort')

    assert_response :unprocessable_entity
    assert @user.reload.authenticate('password123')
  end

  test 'ungültiges Token bleibt 404, auch bei regelkonformem Passwort' do
    post '/api/v2/reset_password',
         params: { reset_token: 'gibtesnicht',
                   user: { password: 'NeuesGeheim1234', password_confirmation: 'NeuesGeheim1234' } },
         as: :json

    assert_response :not_found
    assert @user.reload.authenticate('password123')
  end
end
