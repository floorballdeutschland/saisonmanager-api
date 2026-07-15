require 'test_helper'

# Render-Verhalten des admin-pflegbaren E-Mail-Bodys (TemplatedMailer-Concern).
class TemplatedMailerBodyTest < ActionMailer::TestCase
  setup do
    @user = User.create!(
      user_name: "bodyuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      email: 'body@example.de',
      permissions: [],
      teams: []
    )
  end

  test 'gepflegter Body ersetzt das ERB-View' do
    EmailTemplate.create!(
      mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de',
      body: '<p>Individueller Text im Body</p>'
    )
    mail = UserMailer.reset_password(@user)
    assert_includes mail.body.encoded, 'Individueller Text im Body'
  end

  test 'ohne gepflegten Body greift unverändert das ERB-View' do
    mail = UserMailer.reset_password(@user)
    assert mail.body.encoded.present?
  end

  test 'Passwort-Reset-Mail nennt den Benutzernamen und den Login-Hinweis' do
    mail = UserMailer.reset_password(@user)
    assert_includes mail.body.encoded, @user.user_name
    assert_includes mail.body.encoded, 'E-Mail-Adresse'
  end

  test 'nicht erlaubte Tags im Body werden sanitisiert' do
    EmailTemplate.create!(
      mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de',
      body: '<p>ok</p><script>alert(1)</script>'
    )
    mail = UserMailer.reset_password(@user)
    assert_includes mail.body.encoded, 'ok'
    assert_not_includes mail.body.encoded, '<script>'
  end
end
