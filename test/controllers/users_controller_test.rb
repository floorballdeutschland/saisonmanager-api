require 'test_helper'

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = create(:user)
    @token = @user.issue_password_reset_token
    @user.save!(validate: false)
  end

  # Aus dem dekodierten Teil lesen: Im kodierten Body kann quoted-printable
  # das Token umbrechen.
  def link_token_from(mail)
    part = mail.html_part || mail.text_part || mail
    part.body.decoded[%r{/neues-passwort/([A-Za-z0-9_-]+)}, 1]
  end

  def reset_password(password, token: @token)
    post '/api/v2/reset_password',
         params: { reset_token: token,
                   user: { password: password, password_confirmation: password } },
         as: :json
  end

  test 'neues Passwort nach den Regeln wird gesetzt und verbraucht das Token' do
    reset_password('NeuesGeheim1234')

    assert_response :ok
    assert @user.reload.authenticate('NeuesGeheim1234')
    assert_nil @user.password_reset_token_digest
    assert_nil @user.password_reset_expires_at

    reset_password('NochEinGeheim123')
    assert_response :not_found
  end

  test 'zu kurzes Passwort wird abgelehnt und das Token bleibt gültig' do
    reset_password('Geheim12345')

    assert_response :unprocessable_entity
    assert_equal PasswordPolicy::REQUIREMENTS, JSON.parse(response.body)['message']
    assert @user.reload.authenticate('password123')
    assert_not_nil @user.reload.password_reset_token_digest
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

  test 'in der Datenbank steht nur der Digest, nicht das Token' do
    assert_equal Digest::SHA256.hexdigest(@token), @user.reload.password_reset_token_digest
    assert_not_equal @token, @user.password_reset_token_digest
    assert_not User.column_names.include?('password_reset_token')
  end

  test 'abgelaufener Link wird abgewiesen' do
    @user.update_column(:password_reset_expires_at, 1.minute.ago)

    reset_password('NeuesGeheim1234')

    assert_response :not_found
    assert @user.reload.authenticate('password123')
  end

  test 'Link gilt 24 Stunden' do
    travel 23.hours do
      reset_password('NeuesGeheim1234')
      assert_response :ok
    end
  end

  test 'neuer Link macht den alten ungültig' do
    @user.issue_password_reset_token
    @user.save!(validate: false)

    reset_password('NeuesGeheim1234')

    assert_response :not_found
  end

  test 'archiviertes Konto setzt kein Passwort' do
    @user.update_column(:archived_at, Time.current)

    reset_password('NeuesGeheim1234')

    assert_response :not_found
  end

  test 'leeres Token trifft kein Konto ohne Link' do
    other = create(:user)
    assert_nil other.password_reset_token_digest

    reset_password('NeuesGeheim1234', token: '')

    assert_response :not_found
  end

  test 'Passwort vergessen schickt einen Link, dessen Digest gespeichert ist' do
    @user.update_columns(password_reset_token_digest: nil, email: 'reset@example.de')

    assert @user.send_reset_information
    link_token = link_token_from(ActionMailer::Base.deliveries.last)

    assert_equal Digest::SHA256.hexdigest(link_token), @user.reload.password_reset_token_digest
    assert_in_delta User::PASSWORD_RESET_VALIDITY.from_now, @user.password_reset_expires_at, 5.seconds
  end

  test 'Einladung fuer ein neues Schiedsrichterkonto gilt 14 Tage' do
    @user.update_column(:email, 'konto@example.de')

    assert @user.send_referee_account_information
    link_token = link_token_from(ActionMailer::Base.deliveries.last)

    assert_equal Digest::SHA256.hexdigest(link_token), @user.reload.password_reset_token_digest
    assert_in_delta User::ACCOUNT_INVITATION_VALIDITY.from_now, @user.password_reset_expires_at, 5.seconds
  end
end
