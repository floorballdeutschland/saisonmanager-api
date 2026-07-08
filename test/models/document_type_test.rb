require 'test_helper'

# Dokumentarten-Katalog: Key-Generierung, Altersregel (Stichtag = Datum der
# Lizenzbeantragung) und Auflösung der pro Spieler erforderlichen Keys.
class DocumentTypeTest < ActiveSupport::TestCase
  test 'key wird aus dem Namen generiert, Kollisionen bekommen Suffix' do
    a = DocumentType.create!(name: 'Sportärztliches Attest')
    assert_equal 'sportarztliches_attest', a.key

    b = DocumentType.create!(name: 'Sportärztliches Attest', game_operation: create(:game_operation))
    assert_equal 'sportarztliches_attest_2', b.key
  end

  test 'name ist je Verband eindeutig, global und verbandsspezifisch koexistieren' do
    DocumentType.create!(name: 'Attest')
    duplicate = DocumentType.new(name: 'attest')
    assert_not duplicate.valid?, 'gleicher Name global (case-insensitive) muss abgelehnt werden'

    scoped = DocumentType.new(name: 'Attest', game_operation: create(:game_operation))
    assert scoped.valid?
  end

  test 'required_for? prüft das Alter am Tag der Lizenzbeantragung' do
    attest = DocumentType.new(name: 'Attest', required_below_age: 16)
    requested_at = Time.zone.parse('2026-07-01 12:00')

    assert attest.required_for?('2010-08-01', requested_at), '15 Jahre alt → erforderlich'
    assert_not attest.required_for?('2010-06-01', requested_at), 'bereits 16 → nicht mehr erforderlich'
    assert_not attest.required_for?(Date.new(2010, 7, 1), requested_at), 'genau am 16. Geburtstag → nicht erforderlich'
  end

  test 'required_for? ohne Altersgrenze oder ohne lesbares Geburtsdatum: erforderlich' do
    always = DocumentType.new(name: 'USE')
    assert always.required_for?('2010-08-01', Time.current)

    with_age = DocumentType.new(name: 'Attest', required_below_age: 16)
    assert with_age.required_for?(nil, Time.current), 'ohne Geburtsdatum lieber anfordern'
    assert with_age.required_for?('unbekannt', Time.current), 'unlesbares Geburtsdatum lieber anfordern'
  end

  test 'required_keys filtert altersabhängige Keys und behält Freitext-Altbestand' do
    DocumentType.create!(name: 'Zustimmung', key: 'parental_consent', required_below_age: 18)
    DocumentType.create!(name: 'USE', key: 'use')

    keys = DocumentType.required_keys(%w[use parental_consent legacy_freitext],
                                      birthdate: '1990-01-01', requested_at: Time.current)
    assert_equal %w[use legacy_freitext], keys,
                 'Volljährig: parental_consent entfällt; unbekannte Keys bleiben erforderlich'
  end

  test 'validity erlaubt nur once und per_season' do
    assert DocumentType.new(name: 'A', validity: 'once').valid?
    assert DocumentType.new(name: 'B', validity: 'per_season').per_season?
    assert_not DocumentType.new(name: 'C', validity: 'jaehrlich').valid?
  end
end
