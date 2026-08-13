require 'test_helper'

# Die drei gestaffelten Ansetzungs-Optionen (#403) werden ausschließlich in
# StateAssociation#referee_assignment_mode ausgewertet. Alles andere – Menü,
# Autorisierung, additional_references – fragt hier nach, damit die Regel nicht an
# mehreren Stellen auseinanderläuft.
class StateAssociationRefereeAssignmentModeTest < ActiveSupport::TestCase
  test 'ohne Hauptschalter setzt nur die SBK an' do
    sa = create(:state_association)

    assert_equal :none, sa.referee_assignment_mode
    assert_not sa.person_level_assignment_active?
    assert_not sa.club_level_assignment_active?
  end

  test 'Hauptschalter allein ergibt den reduzierten Vereins-Modus' do
    sa = create(:state_association, referee_assignment_external_enabled: true)

    assert_equal :club, sa.referee_assignment_mode
    assert sa.club_level_assignment_active?
    assert_not sa.person_level_assignment_active?
  end

  test 'Hauptschalter plus Personenebene ergibt den Personen-Modus' do
    sa = create(:state_association, referee_assignment_enabled: true)

    assert_equal :person, sa.referee_assignment_mode
    assert sa.person_level_assignment_active?
    # Die Personenebene gewinnt: der reduzierte Modus ist damit aus, sonst
    # bearbeiteten zwei Wege dasselbe Spiel.
    assert_not sa.club_level_assignment_active?
  end

  test 'Personenebene ohne Hauptschalter zaehlt als komplett aus' do
    sa = create(:state_association, referee_assignment_enabled: true)
    # Zustand, den die Maske ausgraut und der Controller aufräumt – per
    # update_column bewusst am Modell vorbei hergestellt, weil ein abgeschalteter
    # Hauptschalter ein gesetztes referee_assignment_enabled im Datensatz
    # zurücklassen kann.
    sa.update_column(:referee_assignment_external_enabled, false)

    assert_equal :none, sa.reload.referee_assignment_mode
  end
end
