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

  # Gueltige Signatur, falscher Inhalt: Das ist ein Fehler bei uns, kein
  # Besucherfall, und muss deshalb auffallen statt still nil zu liefern.
  test 'ein signiertes Cookie mit unerwartetem Inhalt wird gemeldet' do
    odd = Rails.application.message_verifier(:public_session)
               .generate({ 'id' => 42 }, purpose: :public_session)
    warnings = []

    Rails.logger.stub(:warn, ->(msg) { warnings << msg }) do
      assert_nil PublicSession.verify(odd)
    end

    assert(warnings.any? { |w| w.include?('unerwartetem Inhalt') })
  end

  test 'ein manipuliertes Cookie wird nicht gemeldet, das ist der Normalfall' do
    warnings = []

    Rails.logger.stub(:warn, ->(msg) { warnings << msg }) do
      assert_nil PublicSession.verify('frei-erfunden--abc')
    end

    assert_empty warnings
  end

  test 'IPv4 zaehlt je Adresse, IPv6 je /64' do
    assert_equal '203.0.113.7', PublicSession.issuer_key('203.0.113.7')
    assert_equal PublicSession.issuer_key('2001:db8:1:2::1'), PublicSession.issuer_key('2001:db8:1:2:ffff::9')
    assert_not_equal PublicSession.issuer_key('2001:db8:1:2::1'), PublicSession.issuer_key('2001:db8:1:3::1')
  end

  test 'erneuert wird erst nach der Haelfte der Laufzeit' do
    _value, payload = PublicSession.issue

    assert_not payload.renew?
    assert payload.renew?(Time.current + PublicSession::RENEW_AFTER)
  end
end
