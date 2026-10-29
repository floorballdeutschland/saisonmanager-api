require 'test_helper'

class PublicSessionTest < ActiveSupport::TestCase
  test 'ein ausgestelltes Cookie wird mit Kennung und Zeitpunkt wiedererkannt' do
    value, payload = PublicSession.issue

    verified = PublicSession.verify(value)

    assert_equal payload.id, verified.id
    assert_equal payload.issued_at, verified.issued_at
  end

  test 'ein verlaengertes Cookie behaelt seine Kennung' do
    value, = PublicSession.issue(id: 'abc123')

    assert_equal 'abc123', PublicSession.verify(value).id
  end

  test 'ein manipuliertes Cookie gilt nicht' do
    value, = PublicSession.issue

    assert_nil PublicSession.verify("#{value}x")
    assert_nil PublicSession.verify('frei-erfunden')
    assert_nil PublicSession.verify(nil)
  end

  # Ohne eigenen Zweck liesse sich eine anderswo mit demselben Schluessel
  # signierte Nachricht als Sitzung ausgeben.
  test 'eine fuer einen anderen Zweck signierte Nachricht gilt nicht' do
    foreign = Rails.application.message_verifier(:public_session)
                   .generate({ 'id' => 'x', 'iat' => Time.current.to_i }, purpose: :other)

    assert_nil PublicSession.verify(foreign)
  end

  test 'ein Cookie laeuft nach 24 Stunden ab' do
    value, = PublicSession.issue

    travel PublicSession::TTL + 1.second do
      assert_nil PublicSession.verify(value)
    end
  end

  test 'erneuert wird erst nach der Haelfte der Laufzeit' do
    _value, payload = PublicSession.issue

    assert_not payload.renew?
    assert payload.renew?(Time.current + PublicSession::RENEW_AFTER)
  end
end
