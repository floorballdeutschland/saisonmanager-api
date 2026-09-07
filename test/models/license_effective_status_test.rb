require 'test_helper'

# Der Status eines Lizenz-Hashes, getrennt in „was zuletzt gesetzt wurde" und
# „was ohne Sperre gelten wuerde" (#605).
#
# Dieses Modul ist die einzige Stelle, an der die drei Lizenzlisten des
# Spieltags und die Verbandslisten ihren Basis-Status holen; bisher war es nur
# ueber seine Aufrufer geprueft. Die Reihenfolge der beiden Schritte ist
# entscheidend und nicht offensichtlich: `reject` laeuft VOR `max_by`, ein
# Sperr-Eintrag ohne Zeitstempel erreicht den Vergleich also gar nicht.
class LicenseEffectiveStatusTest < ActiveSupport::TestCase
  def license(*history)
    { 'history' => history }
  end

  def entry(status, created_at)
    { 'license_status_id' => status, 'created_at' => created_at }
  end

  test 'ohne Sperre ist der Basis-Eintrag der juengste Eintrag' do
    l = license(entry(License::REQUESTED, '2026-01-01T10:00:00Z'),
                entry(License::APPROVED, '2026-01-05T10:00:00Z'))

    assert_equal License::APPROVED, LicenseEffectiveStatus.base_status_id(l)
    assert_equal License::APPROVED, LicenseEffectiveStatus.current_status_id(l)
  end

  test 'der Basis-Eintrag ueberspringt die Sperre, der aktuelle nicht' do
    l = license(entry(License::APPROVED, '2026-01-05T10:00:00Z'),
                entry(License::SUSPENDED, '2026-02-01T10:00:00Z'))

    assert_equal License::APPROVED, LicenseEffectiveStatus.base_status_id(l)
    assert_equal License::SUSPENDED, LicenseEffectiveStatus.current_status_id(l)
  end

  # Gelesen wird ueber den Zeitstempel, nicht ueber die Position: Angehaengt
  # wird die History an vielen Stellen, sortiert ist sie nirgends garantiert.
  test 'die Reihenfolge im Array entscheidet nicht' do
    l = license(entry(License::APPROVED, '2026-03-01T10:00:00Z'),
                entry(License::WITHDRAWN, '2026-01-01T10:00:00Z'))

    assert_equal License::APPROVED, LicenseEffectiveStatus.base_status_id(l)
  end

  # Der Absturz, der im Altbestand steckt: „comparison of NilClass with String
  # failed" -- eine 500 auf dem oeffentlichen Lizenzlink kurz vor Anwurf.
  test 'ein Eintrag ohne Zeitstempel wirft nicht' do
    l = license(entry(License::APPROVED, '2026-01-05T10:00:00Z'),
                { 'license_status_id' => License::APPROVED })

    assert_equal License::APPROVED, LicenseEffectiveStatus.base_status_id(l)
  end

  # Und derselbe Fall am Sperr-Eintrag: Er wird verworfen, bevor verglichen
  # wird, darf also auch ohne Zeitstempel nichts umwerfen.
  test 'ein Sperr-Eintrag ohne Zeitstempel wirft nicht und gilt nicht als Basis' do
    l = license(entry(License::APPROVED, '2026-01-05T10:00:00Z'),
                { 'license_status_id' => License::SUSPENDED })

    assert_equal License::APPROVED, LicenseEffectiveStatus.base_status_id(l)
  end

  # Die Status-ID liegt im JSONB nicht typgarantiert vor.
  test 'ein Status als Zeichenkette wird wie die Zahl gelesen' do
    l = license(entry(License::APPROVED.to_s, '2026-01-05T10:00:00Z'),
                entry(License::SUSPENDED.to_s, '2026-02-01T10:00:00Z'))

    assert_equal License::APPROVED, LicenseEffectiveStatus.base_status_id(l)
  end

  test 'ohne Historie und ohne Lizenz bleibt es bei 0 und nil' do
    assert_nil LicenseEffectiveStatus.base_entry(nil)
    assert_nil LicenseEffectiveStatus.base_entry(license)
    assert_equal 0, LicenseEffectiveStatus.base_status_id(nil)
  end

  # Eine Lizenz, deren einziger Eintrag die Sperre ist: Sie hat keinen
  # Basis-Status, und die Lizenzlisten lassen sie deshalb weg. Auf Prod gibt es
  # davon keine (04.09.2026 gezaehlt), der Fall ist hier festgehalten, damit er
  # nicht unbemerkt zu einer 500 wird.
  test 'eine Lizenz mit ausschliesslich einem Sperr-Eintrag hat keinen Basis-Status' do
    l = license(entry(License::SUSPENDED, '2026-02-01T10:00:00Z'))

    assert_nil LicenseEffectiveStatus.base_entry(l)
    assert_equal License::SUSPENDED, LicenseEffectiveStatus.current_status_id(l)
  end

  # Spielberechtigung heisst ausschliesslich `erteilt` -- ein beantragter
  # Antrag berechtigt nicht zum Einsatz und zaehlt kein Spiel einer Sperre ab.
  test 'eligible? gilt nur fuer eine erteilte Lizenz' do
    assert LicenseEffectiveStatus.eligible?(license(entry(License::APPROVED, '2026-01-05T10:00:00Z')))
    assert_not LicenseEffectiveStatus.eligible?(license(entry(License::REQUESTED, '2026-01-05T10:00:00Z')))
    # Auch die gesperrte Lizenz ist „eligible", weil der Basis-Status zaehlt --
    # genau darauf beruht das Abzaehlen einer Sperre ueber X Spiele.
    assert LicenseEffectiveStatus.eligible?(
      license(entry(License::APPROVED, '2026-01-05T10:00:00Z'),
              entry(License::SUSPENDED, '2026-02-01T10:00:00Z'))
    )
  end
end
