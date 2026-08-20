require 'test_helper'

# StateAssociation.build_tree / .root_id / .ids_under und
# GameOperation.id_by_state_association: die Grundlage der Zustaendigkeit am
# Verein (Club#main_game_operation_id).
#
# Eigene Datei, weil die zwei Riegel in build_tree Rechteschutz sind und ueber
# Club-Tests nur mitgetestet wuerden: Auf state_associations.parent_id liegt kein
# Fremdschluessel, und parent_must_not_create_cycle haelt neue Ringe heraus, aber
# nicht update_column oder rohes SQL.
class AssociationTreeTest < ActiveSupport::TestCase
  test 'root_id nimmt den Verband selbst, wenn er parentlos ist' do
    sa = create(:state_association)

    assert_equal sa.id, StateAssociation.root_id(sa.id)
  end

  test 'root_id laeuft die Kette ueber mehrere Ebenen bis zur Wurzel' do
    wurzel = create(:state_association)
    mitte = create(:state_association, parent: wurzel)
    blatt = create(:state_association, parent: mitte)

    assert_equal wurzel.id, StateAssociation.root_id(blatt.id)
    assert_equal wurzel.id, StateAssociation.root_id(mitte.id)
  end

  test 'root_id ist nil fuer leere und unbekannte Kennungen' do
    assert_nil StateAssociation.root_id(nil)
    assert_nil StateAssociation.root_id('')
    assert_nil StateAssociation.root_id(999_999)
  end

  # Ohne diesen Riegel liefe die Aufloesung in eine Endlosschleife. Ein Ring kann
  # nur ueber update_column oder rohes SQL entstehen, genau so wird er hier auch
  # hergestellt.
  test 'build_tree macht einen Verband im Ringverweis zu seinem eigenen Verbund' do
    a = create(:state_association)
    b = create(:state_association, parent: a)
    a.update_column(:parent_id, b.id)
    Current.reset_association_structure

    assert_equal a.id, StateAssociation.root_id(a.id)
    assert_equal b.id, StateAssociation.root_id(b.id)
  end

  test 'build_tree faengt einen Selbstverweis ab' do
    sa = create(:state_association)
    sa.update_column(:parent_id, sa.id)
    Current.reset_association_structure

    assert_equal sa.id, StateAssociation.root_id(sa.id)
  end

  # Zeigt parent_id auf einen geloeschten Verband, bleibt der letzte bekannte die
  # Wurzel. Ohne die Pruefung waere die Wurzel eine ID, die es nicht gibt, und
  # alle Vereine darunter haetten lautlos keinen zustaendigen Spielbetrieb mehr.
  test 'build_tree haelt am letzten bekannten Verband, wenn der Parent fehlt' do
    sa = create(:state_association)
    sa.update_column(:parent_id, 999_999)
    Current.reset_association_structure

    assert_equal sa.id, StateAssociation.root_id(sa.id)
  end

  # Die Eigenschaft, auf die sich Club.responsible_state_association_ids und
  # Club.assigned_state_association_ids verlassen: Die zurueckgegebene Wurzel ist
  # selbst ein Schluessel im Baum und ihre eigene Wurzel. Nur deshalb koennen die
  # beiden Methoden nicht auseinanderlaufen.
  test 'jede Wurzel ist ihre eigene Wurzel' do
    wurzel = create(:state_association)
    create(:state_association, parent: wurzel)
    ring = create(:state_association)
    ring.update_column(:parent_id, ring.id)
    Current.reset_association_structure

    roots = StateAssociation.tree[:roots]
    roots.each_value { |r| assert_equal r, roots[r], "Wurzel #{r} ist nicht ihre eigene Wurzel" }
  end

  test 'ids_under liefert den Teilbaum einschliesslich der Wurzel' do
    wurzel = create(:state_association)
    kind = create(:state_association, parent: wurzel)
    enkel = create(:state_association, parent: kind)
    fremd = create(:state_association)

    ids = StateAssociation.ids_under([wurzel.id])
    assert_equal [wurzel.id, kind.id, enkel.id].sort, ids.sort
    assert_not_includes ids, fremd.id
  end

  test 'ids_under liefert fuer einen Unterverband nichts' do
    wurzel = create(:state_association)
    kind = create(:state_association, parent: wurzel)

    assert_empty StateAssociation.ids_under([kind.id])
  end

  # --- Current: die Karten muessen im selben Request mitgehen ----------------
  #
  # Beide after_commit-Haken sehen wie Kosmetik aus. Ohne sie arbeitet der Rest
  # desselben Requests mit dem Stand von vorher, und ein gerade eingerichteter
  # Verband ist fuer seine Vereine noch nicht zustaendig.

  test 'ein neuer Spielbetrieb ist im selben Request zustaendig' do
    sa = create(:state_association)
    club = create(:club, state_association_id: sa.id)
    assert_nil club.main_game_operation_id, 'Ausgangslage: kein Spielbetrieb'

    go = create(:game_operation, state_association_id: sa.id)

    assert_equal go.id, club.main_game_operation_id,
                 'die Karte muss nach dem Anlegen neu aufgeloest werden'
    assert_equal go.id, GameOperation.by_id[go.id]&.id
  end

  test 'ein neuer Elternverband wirkt im selben Request' do
    wurzel = create(:state_association)
    go = create(:game_operation, state_association_id: wurzel.id)
    kind = create(:state_association)
    club = create(:club, state_association_id: kind.id)
    assert_nil club.main_game_operation_id

    kind.update!(parent: wurzel)

    assert_equal go.id, club.main_game_operation_id
  end
end
