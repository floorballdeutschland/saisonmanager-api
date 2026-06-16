require 'test_helper'

class EmailTemplateTest < ActiveSupport::TestCase
  test 'resolve findet die Vorlage für Mailer/Action/Sprache' do
    template = EmailTemplate.create!(
      mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de',
      subject: 'Betreff DE'
    )

    assert_equal template, EmailTemplate.resolve('UserMailer', 'reset_password', 'de')
  end

  test 'resolve fällt auf die Default-Sprache zurück' do
    de = EmailTemplate.create!(
      mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de',
      subject: 'Betreff DE'
    )

    assert_equal de, EmailTemplate.resolve('UserMailer', 'reset_password', 'en')
  end

  test 'resolve liefert nil ohne passenden Datensatz' do
    assert_nil EmailTemplate.resolve('UserMailer', 'reset_password', 'de')
  end

  test 'action_name ist eindeutig pro mailer_class und locale' do
    EmailTemplate.create!(mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de')

    duplicate = EmailTemplate.new(mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de')

    assert_not duplicate.valid?
    assert_predicate duplicate.errors[:action_name], :present?
  end

  test 'derselbe Mailer/Action ist je Sprache erlaubt' do
    EmailTemplate.create!(mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'de')
    en = EmailTemplate.new(mailer_class: 'UserMailer', action_name: 'reset_password', locale: 'en')

    assert en.valid?
  end
end
