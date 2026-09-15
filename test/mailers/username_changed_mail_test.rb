require 'test_helper'

class UsernameChangedMailTest < ActionMailer::TestCase
  test 'nennt alten und neuen Benutzernamen' do
    user = create(:user, user_name: 'sr-serocki', first_name: 'Kamil', email: 'gast@example.org')

    mail = UserMailer.username_changed(user, 'sr-8725')

    assert_equal ['gast@example.org'], mail.to
    assert_equal 'Your username in Saisonmanager has changed', mail.subject
    assert_equal ['rsk@floorball.de'], mail.reply_to
    body = mail.body.encoded
    assert_includes body, 'sr-serocki'
    assert_includes body, 'sr-8725'
    assert_includes body, 'Kamil'
  end

  test 'enthaelt keinen Passwort-Link' do
    user = create(:user, user_name: 'sr-jarysz', email: 'gast@example.org')

    mail = UserMailer.username_changed(user, 'sr-8726')

    assert_not_includes mail.body.encoded, 'neues-passwort'
  end
end
