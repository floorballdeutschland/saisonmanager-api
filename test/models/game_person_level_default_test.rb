require 'test_helper'

# Verbandsoption „Standardmäßig durch Ansetzer*in": neue Spiele gleich für die
# Personenebene markieren, damit die SBK das nicht je Spieltag anklicken muss.
# Beide Anlege-Wege fragen Game.person_level_assignment_default_for?.
class GamePersonLevelDefaultTest < ActiveSupport::TestCase
  setup { create(:setting) }

  test 'Voreinstellung aktiv markiert neue Spiele' do
    sa = create(:state_association, referee_assignment_enabled: true,
                                    person_level_assignment_default: true)
    league = create(:league, game_operation: create(:game_operation, state_association_id: sa.id))

    assert Game.person_level_assignment_default_for?(league)
  end

  test 'ohne Voreinstellung bleiben neue Spiele unmarkiert' do
    sa = create(:state_association, referee_assignment_enabled: true)
    league = create(:league, game_operation: create(:game_operation, state_association_id: sa.id))

    assert_not Game.person_level_assignment_default_for?(league)
  end

  test 'im reduzierten Modus greift die Voreinstellung nicht' do
    # Sonst entstünden Spiele, die dort gesperrt und mangels Personenebene in
    # keiner Ansicht bearbeitbar wären.
    sa = create(:state_association, referee_assignment_external_enabled: true,
                                    person_level_assignment_default: true)
    league = create(:league, game_operation: create(:game_operation, state_association_id: sa.id))

    assert_not Game.person_level_assignment_default_for?(league)
  end

  test 'nationaler Spielbetrieb hat keine Voreinstellung' do
    league = create(:league, game_operation: create(:game_operation, :national))

    assert_not Game.person_level_assignment_default_for?(league)
  end

  # Der Bundesspielbetrieb wird über GameOperation#national erkannt, NICHT über
  # einen fehlenden Landesverband: die FD-GameOperation ist mit ihrem
  # StateAssociation verknüpft (Verbandslogo, siehe User#permission_hash). Liefe
  # die Erkennung über `state_association.nil?`, fiele FD aus der Ansetzung,
  # sobald an diesem Datensatz jemand den Hauptschalter abwählt.
  test 'nationaler Spielbetrieb bleibt auf der Personenebene, auch mit Landesverband' do
    sa = create(:state_association) # alle Schalter aus
    league = create(:league, game_operation: create(:game_operation, :national,
                                                    state_association_id: sa.id))

    assert_equal :person, league.referee_assignment_mode
    assert Game.person_level_assignment_allowed_for?(league)
  end

  test 'Markierung ist im reduzierten Modus nicht erlaubt' do
    sa = create(:state_association, referee_assignment_external_enabled: true)
    league = create(:league, game_operation: create(:game_operation, state_association_id: sa.id))

    assert_equal :club, league.referee_assignment_mode
    assert_not Game.person_level_assignment_allowed_for?(league)
  end
end
