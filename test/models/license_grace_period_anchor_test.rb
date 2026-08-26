require 'test_helper'

# Der Anker der Karenzzeit: Ab welchem `beantragt`-Eintrag laeuft die kostenfreie
# Stunde? Die Frage hat Geldfolgen, denn innerhalb der Stunde wird die Lizenz
# ersatzlos geloescht statt auf "zurueckgezogen" gesetzt.
class LicenseGracePeriodAnchorTest < ActiveSupport::TestCase
  def requested(at, revoked: false)
    entry = { 'license_status_id' => License::REQUESTED, 'created_at' => at.iso8601 }
    entry[License::REVOKED_REJECTION_KEY] = true if revoked
    entry
  end

  test 'nimmt den jüngsten unmarkierten Antrag' do
    older = requested(3.days.ago)
    newer = requested(1.hour.ago)

    assert_equal newer, License.grace_period_anchor([older, newer])
  end

  test 'überspringt den Eintrag aus einem Widerruf' do
    original = requested(3.days.ago)
    revoke = requested(1.minute.ago, revoked: true)

    assert_equal original, License.grace_period_anchor([original, revoke]),
                 'der Widerruf darf die Frist nicht neu starten'
  end

  test 'ignoriert andere Statuswerte' do
    original = requested(3.days.ago)
    denied = { 'license_status_id' => License::DENIED, 'created_at' => 1.day.ago.iso8601 }

    assert_equal original, License.grace_period_anchor([original, denied])
  end

  # Sichere Richtung: Ohne verwertbaren Antrag darf keine Gratis-Loeschung
  # entstehen. Der Aufrufer behandelt nil wie eine abgelaufene Frist.
  test 'liefert nil, wenn nur ein Widerruf übrig bleibt' do
    assert_nil License.grace_period_anchor([requested(1.minute.ago, revoked: true)])
  end

  # Der Wert landet in JSONB und ist damit Bestandsdaten: Wird er geaendert,
  # gelten alle vorhandenen Markierungen als nicht gesetzt und die Luecke ist
  # wieder offen, ohne dass irgendetwas rot wird.
  test 'der Markierungsschluessel bleibt stabil' do
    assert_equal 'revoked_rejection', License::REVOKED_REJECTION_KEY
  end

  # Der Altdaten-Import baut die Historie mit `compact`, `created_at` kann also
  # fehlen. Ohne den Filter wuerfe `max_by` hier einen ArgumentError, und der
  # traefe die Team-Lizenzansicht und das Zurueckziehen gleichzeitig.
  test 'faellt nicht ueber einen Eintrag ohne Zeitpunkt' do
    valid = requested(2.days.ago)
    without = { 'license_status_id' => License::REQUESTED }

    assert_equal valid, License.grace_period_anchor([without, valid])
  end

  test 'liefert nil, wenn nur Eintraege ohne Zeitpunkt uebrig bleiben' do
    assert_nil License.grace_period_anchor([{ 'license_status_id' => License::REQUESTED }])
  end

  test 'liefert nil bei leerer oder fehlender Historie' do
    assert_nil License.grace_period_anchor([])
    assert_nil License.grace_period_anchor(nil)
  end
end
