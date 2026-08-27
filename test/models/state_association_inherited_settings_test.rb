require 'test_helper'

# Hängt an einem Landesverband ein übergeordneter Verbund, kommt der ganze Block
# „Einstellungen" der Verbandsmaske von dort. Die Maske sperrt die Felder, der
# Controller verwirft sie beim Speichern – gelesen wird ausschließlich über die
# effective_*-Methoden, damit ein am Kind stehengebliebener Wert nirgends mehr
# wirkt.
class StateAssociationInheritedSettingsTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
  end

  test 'ohne Verbund pflegt der Landesverband seine Einstellungen selbst' do
    sa = create(:state_association, scan_required: true, report_form_email_enabled: true)

    assert_equal sa, sa.settings_source
    assert sa.effective_scan_required
    assert sa.effective_report_form_email_enabled
    assert_not sa.effective_manual_proceeding_creation
  end

  test 'Kind-LV liest jede Einstellung am Verbund' do
    verbund = create(:state_association,
                     express_license_enabled: true,
                     referee_license_review_enabled: true,
                     scan_required: true,
                     referee_assignment_enabled: true,
                     person_level_assignment_default: true,
                     report_form_email_enabled: true,
                     manual_proceeding_creation: true,
                     requested_license_playable: true)
    child = create(:state_association, parent: verbund)

    assert_equal verbund, child.settings_source
    StateAssociation::INHERITED_SETTINGS.each do |setting|
      assert child.public_send(:"effective_#{setting}"), "#{setting} wurde nicht vom Verbund gelesen"
    end
  end

  test 'eigener Stand des Kind-LV wirkt nicht mehr' do
    verbund = create(:state_association)
    child = create(:state_association, parent: verbund, scan_required: true, report_form_email_enabled: true)

    # Der gespeicherte Stand bleibt bewusst stehen (der Controller verwirft die
    # Felder, statt sie auf false zu zwingen) – gelesen wird er nicht mehr.
    assert child.scan_required
    assert_not child.effective_scan_required
    assert_not child.effective_report_form_email_enabled
  end

  test 'Einstellungen kommen aus der Wurzel der Kette, nicht von der Zwischenstufe' do
    wurzel = create(:state_association, scan_required: true)
    mitte = create(:state_association, parent: wurzel)
    blatt = create(:state_association, parent: mitte)

    assert_equal wurzel, blatt.settings_source
    assert blatt.effective_scan_required
  end

  # Die Zwischenstufe pflegt ihre Einstellungen selbst nicht mehr (ihre Felder
  # sind in der Maske gesperrt), ihr gespeicherter Stand ist also derselbe
  # Ueberbleibsel-Fall wie beim Blatt. Beide lesen deshalb an der Wurzel.
  #
  # Das ist eine Verhaltensaenderung gegenueber der frueheren Regel fuer den
  # Kontrollprozess der Schiedsrichterlizenzen, die genau eine Ebene hochschaute
  # (`return parent.referee_license_review_enabled if parent`) und damit ein Blatt
  # von der Zwischenstufe bestimmen liess.
  test 'in einer dreistufigen Kette bestimmt die Wurzel, nicht die Zwischenstufe' do
    wurzel = create(:state_association, referee_license_review_enabled: false)
    mitte = create(:state_association, parent: wurzel, referee_license_review_enabled: true)
    blatt = create(:state_association, parent: mitte)

    assert_not mitte.effective_referee_license_review_enabled
    assert_not blatt.effective_referee_license_review_enabled

    wurzel.update!(referee_license_review_enabled: true)

    assert blatt.reload.effective_referee_license_review_enabled
  end

  test 'geloester Verbund gibt dem Landesverband seine Einstellungen zurueck' do
    verbund = create(:state_association)
    child = create(:state_association, parent: verbund, scan_required: true)

    assert_not child.effective_scan_required

    child.update!(parent: nil)

    assert child.effective_scan_required
  end

  test 'Ansetzungsmodus des Kind-LV bestimmt der Verbund' do
    verbund = create(:state_association, referee_assignment_enabled: true)
    # Eigener Datensatz komplett aus: ohne Vererbung waere der Modus :none.
    child = create(:state_association, parent: verbund)

    assert_equal :person, child.referee_assignment_mode
    assert child.person_level_assignment_active?
  end

  test 'Ringverweis aus dem Altbestand laeuft nicht in eine Endlosschleife' do
    a = create(:state_association)
    b = create(:state_association, parent: a)
    # An der Validierung vorbei, wie es nur update_column oder ein Import kann.
    a.update_column(:parent_id, b.id)

    assert_includes [a, b], b.reload.settings_source
  end
end
