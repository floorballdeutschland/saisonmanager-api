require 'test_helper'

# Dokumentarten-Katalog: Key-Generierung, die beiden Formen der Altersregel
# (tagesgenauer Stichtag bzw. Geburtsjahrgang) und Auflösung der pro Spieler
# erforderlichen Keys.
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

  # Über das Liga-Flag kann parental_consent angefordert werden, ohne dass die
  # Dokumentart im Katalog steht (Bestand ohne den Backfill der Migration).
  # Ohne Rückfallregel gälte die Zustimmung dort auch für Volljährige, weil
  # Keys ohne Katalog-Eintrag bewusst immer erforderlich bleiben.
  test 'required_keys kennt die Altersgrenze der Elternzustimmung auch ohne Katalog-Eintrag' do
    assert_empty DocumentType.where(key: 'parental_consent')

    volljaehrig = DocumentType.required_keys(%w[parental_consent],
                                             birthdate: '1990-01-01', requested_at: Time.current)
    assert_empty volljaehrig, 'Volljährige brauchen keine Zustimmung, auch ohne Katalog-Eintrag'

    minderjaehrig = DocumentType.required_keys(%w[parental_consent],
                                               birthdate: 15.years.ago.to_date.to_s, requested_at: Time.current)
    assert_equal %w[parental_consent], minderjaehrig
  end

  # Der Grund für die zweite Form (#483): Wer bei Antragstellung im Sommer noch 15
  # ist, wird in derselben Saison 16 und bräuchte das Attest dann doch — und
  # umgekehrt entfällt es bei einem späten Antrag, obwohl es bei allen
  # Jahrgangskolleg*innen für dieselbe Saison vorliegt. Der Jahrgang trennt sauber.
  test 'required_for? mit Geburtsjahrgang nimmt den ganzen Jahrgang' do
    attest = DocumentType.new(name: 'Attest', required_from_birth_year: 2012)
    requested_at = Time.zone.parse('2026-07-01 12:00')

    assert attest.required_for?('2012-01-01', requested_at), 'Jahrgang genau getroffen, früh im Jahr'
    assert attest.required_for?('2012-12-31', requested_at), 'Jahrgang genau getroffen, spät im Jahr'
    assert attest.required_for?('2015-06-01', requested_at), 'jüngerer Jahrgang → erforderlich'
    assert_not attest.required_for?('2011-12-31', requested_at), 'älterer Jahrgang → nicht erforderlich'
  end

  test 'required_for? mit Geburtsjahrgang sieht das Antragsdatum nicht an' do
    attest = DocumentType.new(name: 'Attest', required_from_birth_year: 2012)

    %w[2026-07-01 2026-12-31 2027-06-30 2030-01-01].each do |day|
      requested_at = Time.zone.parse("#{day} 12:00")
      assert attest.required_for?('2012-05-05', requested_at), "#{day}: Jahrgang bleibt erforderlich"
      assert_not attest.required_for?('2011-05-05', requested_at), "#{day}: älterer Jahrgang bleibt draußen"
    end
  end

  test 'required_for? mit Geburtsjahrgang: ohne lesbares Geburtsdatum erforderlich' do
    attest = DocumentType.new(name: 'Attest', required_from_birth_year: 2012)

    assert attest.required_for?(nil, Time.current), 'ohne Geburtsdatum lieber anfordern'
    assert attest.required_for?('unbekannt', Time.current), 'unlesbares Geburtsdatum lieber anfordern'
  end

  test 'required_keys filtert auch über den Geburtsjahrgang' do
    DocumentType.create!(name: 'Attest', key: 'attest', required_from_birth_year: 2012)

    jung = DocumentType.required_keys(%w[attest], birthdate: '2013-09-01', requested_at: Time.current)
    assert_equal %w[attest], jung

    alt = DocumentType.required_keys(%w[attest], birthdate: '2011-09-01', requested_at: Time.current)
    assert_empty alt
  end

  # Die beiden Formen schließen sich aus, leer bleiben muss weiterhin gehen.
  test 'nur eine der beiden Altersregeln darf gesetzt sein' do
    beides = DocumentType.new(name: 'Attest', required_below_age: 16, required_from_birth_year: 2012)
    assert_not beides.valid?
    assert_match(/nur eine Altersregel/, beides.errors.full_messages.join(' '))

    assert DocumentType.new(name: 'A', required_below_age: 16).valid?
    assert DocumentType.new(name: 'B', required_from_birth_year: 2012).valid?
    assert DocumentType.new(name: 'C').valid?, 'beide leer = immer erforderlich'
  end

  test 'Geburtsjahrgang wird auf plausible Jahre begrenzt' do
    assert_not DocumentType.new(name: 'A', required_from_birth_year: 1899).valid?, 'zu früh'
    assert_not DocumentType.new(name: 'B', required_from_birth_year: Date.current.year + 1).valid?,
               'ein Jahrgang in der Zukunft trifft niemanden und ist ein Tippfehler'
    assert DocumentType.new(name: 'C', required_from_birth_year: Date.current.year).valid?
  end

  # Die Elternzustimmung ohne Katalog-Eintrag bleibt altersbasiert; der Jahrgang ist
  # nichts, was sich ohne Eintrag herleiten ließe. Getestet über das Verhalten und
  # nicht über die Konstante: Ein Konstantentest kann aus keinem fachlichen Grund
  # fehlschlagen und sagt dem nächsten Leser nicht, was daran falsch wäre.
  test 'Elternzustimmung ohne Katalog-Eintrag bleibt am Alter, nicht am Jahrgang' do
    assert_empty DocumentType.where(key: 'parental_consent')

    minderjaehrig = DocumentType.required_keys(%w[parental_consent],
                                               birthdate: 15.years.ago.to_date.to_s,
                                               requested_at: Time.current)
    assert_equal %w[parental_consent], minderjaehrig

    # Volljährig, aber ein Jahrgang, der bei einer Jahrgangsregel noch drin wäre:
    # ohne Katalog-Eintrag zählt allein das Alter.
    volljaehrig = DocumentType.required_keys(%w[parental_consent],
                                             birthdate: 19.years.ago.to_date.to_s,
                                             requested_at: Time.current)
    assert_empty volljaehrig
  end

  # Ein Katalog-Eintrag schlägt die Rückfallregel: Trägt ein Verband für
  # parental_consent eine Jahrgangsregel ein, gilt die und nicht die 18. Der Zweig
  # ist erreichbar, weil required_keys `catalog[k] || fallback_type(k)` nimmt.
  test 'ein Katalog-Eintrag fuer parental_consent schlaegt die Rueckfallregel' do
    DocumentType.create!(name: 'Zustimmung', key: 'parental_consent',
                         required_from_birth_year: 2012)

    minderjaehrig_alter_jahrgang = DocumentType.required_keys(
      %w[parental_consent], birthdate: '2011-01-01', requested_at: Time.current
    )
    assert_empty minderjaehrig_alter_jahrgang,
                 'der Katalog-Eintrag entscheidet, obwohl die Person unter 18 ist'

    im_jahrgang = DocumentType.required_keys(
      %w[parental_consent], birthdate: '2013-01-01', requested_at: Time.current
    )
    assert_equal %w[parental_consent], im_jahrgang
  end

  test 'validity erlaubt nur once und per_season' do
    assert DocumentType.new(name: 'A', validity: 'once').valid?
    assert DocumentType.new(name: 'B', validity: 'per_season').per_season?
    assert_not DocumentType.new(name: 'C', validity: 'jaehrlich').valid?
  end
end
