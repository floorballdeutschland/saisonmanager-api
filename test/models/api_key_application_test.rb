require 'test_helper'

class ApiKeyApplicationTest < ActiveSupport::TestCase
  test 'kommerzielle Antraege werden nicht angenommen' do
    application = build(:api_key_application, commercial: true)

    assert_not application.valid?
    assert_includes application.errors.full_messages.join(' '), 'it@floorball.de'
  end

  test 'E-Mail wird normalisiert' do
    application = create(:api_key_application, email: '  Antrag@Example.COM ')

    assert_equal 'antrag@example.com', application.email
  end

  test 'zweiter offener Antrag derselben Adresse und Organisation wird abgewiesen' do
    first = create(:api_key_application, email: 'doppelt@example.com', organisation: 'Verein A')
    second = build(:api_key_application, email: 'doppelt@example.com', organisation: 'Verein A')

    assert_not second.valid?
    assert_includes second.errors.full_messages.join(' '), 'offener Antrag'

    # Nach der Entscheidung ist ein neuer Antrag wieder möglich.
    first.reject!(1, 'Nicht passend')
    assert build(:api_key_application, email: 'doppelt@example.com', organisation: 'Verein A').valid?
  end

  test 'Genehmigen liefert das Abhol-Token und erzeugt noch keinen Key' do
    application = create(:api_key_application)

    token = application.approve!(42, 'Passt')

    assert token.present?
    assert_equal 'approved', application.status
    assert_equal 42, application.decided_by
    assert_nil application.api_key_id, 'Der Key entsteht erst beim Abholen'
    assert_equal 'valid', application.reveal_state
  end

  test 'zweites Genehmigen liefert false' do
    application = create(:api_key_application)
    application.approve!(1)

    assert_not application.approve!(1)
  end

  test 'Ablehnen braucht eine Begruendung' do
    application = create(:api_key_application)

    assert_not application.reject!(1, '   ')
    assert_equal 'pending', application.reload.status

    assert application.reject!(1, 'Kommerzielles Vorhaben')
    assert_equal 'rejected', application.reload.status
  end

  test 'Abholen erzeugt den Key genau einmal' do
    application = create(:api_key_application)
    application.approve!(1)

    raw_key = application.reveal_key!

    assert raw_key.present?
    assert_equal Digest::SHA256.hexdigest(raw_key), application.api_key.key_digest
    assert_equal 'already_revealed', application.reveal_state

    assert_nil application.reveal_key!, 'Der Link darf nur einmal einen Key liefern'
  end

  test 'genehmigter Key entsteht mit Standard-Rate-Limit und ohne Echtzeit-Zugriff' do
    application = create(:api_key_application)
    application.approve!(1)
    application.reveal_key!

    key = application.reload.api_key
    assert_equal ApiTerms::RATE_LIMIT_PER_MINUTE, key.rate_limit
    assert_not key.realtime
    assert_includes key.name, application.organisation
  end

  # nil würde den Throttle in rack_attack.rb überspringen: Der Zugang wäre
  # unbegrenzt, obwohl § 6.1 der Vereinbarung eine Grenze zusagt.
  test 'Standard-Rate-Limit ist gesetzt und nicht unbegrenzt' do
    assert ApiTerms::RATE_LIMIT_PER_MINUTE.is_a?(Integer)
    assert ApiTerms::RATE_LIMIT_PER_MINUTE.positive?
  end

  test 'von Hand angelegte Keys bleiben ohne Rate-Limit' do
    raw_key, key = ApiKey.generate(name: 'Frontend')

    assert raw_key.present?
    assert_nil key.rate_limit, 'Der Key des eigenen Frontends darf nicht gedrosselt werden'
  end

  test 'abgelaufener Abhol-Link liefert keinen Key' do
    application = create(:api_key_application)
    application.approve!(1)
    application.update_column(:reveal_token_expires_at, 1.day.ago)

    assert_equal 'expired', application.reveal_state
    assert_nil application.reveal_key!
  end

  test 'neuer Abhol-Link nur solange nichts abgeholt wurde' do
    application = create(:api_key_application)
    first_token = application.approve!(1)

    second_token = application.issue_new_reveal_token!
    assert second_token.present?
    assert_not_equal first_token, second_token
    assert_nil ApiKeyApplication.find_by_reveal_token(first_token), 'Der alte Link muss ungültig werden'

    application.reveal_key!
    assert_not application.issue_new_reveal_token!
  end

  test 'Token wird nur als Digest gespeichert' do
    application = create(:api_key_application)
    token = application.approve!(1)

    assert_equal Digest::SHA256.hexdigest(token), application.reveal_token_digest
    assert_equal application, ApiKeyApplication.find_by_reveal_token(token)
    assert_nil ApiKeyApplication.find_by_reveal_token('falsch')
    assert_nil ApiKeyApplication.find_by_reveal_token(nil)
  end

  test 'as_json gibt das Abhol-Token nicht heraus' do
    application = create(:api_key_application)
    application.approve!(1)

    assert_not_includes application.as_json.keys.map(&:to_s), 'reveal_token_digest'
  end
end
