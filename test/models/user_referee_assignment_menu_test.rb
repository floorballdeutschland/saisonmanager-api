require 'test_helper'

# Menüpunkt „Ansetzungen" und Modus-Flag nach der Tabelle in #403. Es bleibt ein
# einziger Menüpunkt; welche Ansicht dahinter liegt, sagt
# referee_assignment_club_mode.
class UserRefereeAssignmentMenuTest < ActiveSupport::TestCase
  test 'RSK sieht den Menuepunkt im reduzierten Modus' do
    sa = create(:state_association, referee_assignment_external_enabled: true)
    go = create(:game_operation, state_association_id: sa.id)
    items = create(:user, :rsk_scoped, game_operation_id: go.id).permissions_items

    assert items[:menu_item_referee_assignments]
    assert items[:referee_assignment_club_mode]
    # Verfügbarkeiten gehören zur Personenebene und bleiben aus.
    assert_not items[:menu_item_referee_availability]
  end

  test 'RSK ohne Hauptschalter sieht den Menuepunkt nicht' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    items = create(:user, :rsk_scoped, game_operation_id: go.id).permissions_items

    assert_not items[:menu_item_referee_assignments]
    assert_not items[:referee_assignment_club_mode]
  end

  test 'RSK in einem Verband auf der Personenebene bekommt den Punkt nicht ueber Weg 3' do
    # Dort setzt die Ansetzer-Rolle an; die RSK hat hier nichts zu pflegen.
    sa = create(:state_association, referee_assignment_enabled: true)
    go = create(:game_operation, state_association_id: sa.id)
    items = create(:user, :rsk_scoped, game_operation_id: go.id).permissions_items

    assert_not items[:menu_item_referee_assignments]
    assert_not items[:referee_assignment_club_mode]
  end

  # Häufiger Fall: dieselbe Person ist RSK und Ansetzer. Beide Ansichten dürfen
  # sich nie gleichzeitig zeigen, die Personenebene gewinnt (zwei Reiter sind
  # bewusst nicht gebaut).
  test 'Personenebene gewinnt gegen den reduzierten Modus' do
    sa_club = create(:state_association, referee_assignment_external_enabled: true)
    go_club = create(:game_operation, state_association_id: sa_club.id)
    sa_person = create(:state_association, referee_assignment_enabled: true)
    go_person = create(:game_operation, state_association_id: sa_person.id)

    user = create(:user, permissions: [
      { 'user_group_id' => 3, 'game_operation_id' => go_club.id },
      { 'user_group_id' => 7, 'game_operation_id' => go_person.id }
    ])
    items = user.permissions_items

    assert items[:menu_item_referee_assignments]
    assert_not items[:referee_assignment_club_mode]
  end

  test 'Admin bleibt im Personen-Weg' do
    items = create(:user, :admin).permissions_items

    assert items[:menu_item_referee_assignments]
    assert_not items[:referee_assignment_club_mode]
  end
end
