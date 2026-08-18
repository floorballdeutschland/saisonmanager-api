require 'test_helper'

# Zustaendigkeitsbereich eines Landesverbands (#468): mehrwertiges Bundesland-Feld,
# Vererbung nach unten an den uebergeordneten Spielverbund, und die
# Plausibilitaetspruefung der Kuerzel.
class StateAssociationStatesTest < ActiveSupport::TestCase
  test 'Bundeslaender werden gespeichert und ohne Kinder unveraendert gelesen' do
    sa = create(:state_association, states: %w[de-ni de-hb])

    assert_equal %w[de-hb de-ni], sa.effective_states
    assert sa.covers_state?('de-hb')
    assert_not sa.covers_state?('de-nw')
  end

  test 'Neuer Verband hat einen leeren Bereich und ist fuer nichts zustaendig' do
    sa = create(:state_association)

    assert_equal [], sa.states
    assert_equal [], sa.effective_states
    assert_not sa.covers_state?('de-nw')
  end

  test 'Unbekanntes Kuerzel wird abgelehnt' do
    sa = build(:state_association, states: %w[de-ni de-xx])

    assert_not sa.valid?
    assert_match(/de-xx/, sa.errors.full_messages.join(' '))
  end

  test 'de-sonstige ist kein Zustaendigkeitsbereich' do
    # Die Vereinsmaske kennt den Wert fuer Vereine mit Sitz im Ausland, ein
    # Verband kann dafuer aber nicht zustaendig sein.
    sa = build(:state_association, states: ['de-sonstige'])

    assert_not sa.valid?
    # Auf die Meldung geprueft, damit der Test nicht gruen bleibt, wenn er
    # eines Tages aus einem ganz anderen Grund ungueltig ist.
    assert_match(/de-sonstige/, sa.errors.full_messages.join(' '))
  end

  test 'Schreibweise, Dubletten und Reihenfolge raeumt das Modell auf' do
    # Nicht der Controller: sonst haelt nur die Maske die Invariante, und ein
    # `DE-NW` aus Rake-Task oder Konsole wuerde gespeichert und wirkte nie.
    sa = create(:state_association, states: ['de-NW', ' de-ni ', 'de-nw', ''])

    assert_equal %w[de-ni de-nw], sa.states
  end

  test 'states nil wird zum leeren Bereich statt zum Datenbankfehler' do
    assert_equal [], create(:state_association, states: nil).states
  end

  test 'covers_state? normalisiert das Argument' do
    # Das Argument kommt von aussen, nicht aus `states`: `clubs.state` ist ein
    # freies Textfeld ohne Inclusion-Validierung. Ein `DE-NW` aus einem Import
    # wuerde den Verband sonst stumm von seinen eigenen Spielorten aussperren.
    sa = create(:state_association, states: %w[de-nw])

    assert sa.covers_state?('DE-NW')
    assert sa.covers_state?(' de-nw ')
    assert_not sa.covers_state?('de-he')
  end

  test 'Uebergeordneter Spielverbund erbt die Bundeslaender seiner Kinder' do
    verbund = create(:state_association, states: [])
    create(:state_association, parent: verbund, states: %w[de-sn])
    create(:state_association, parent: verbund, states: %w[de-st de-th])

    assert_equal %w[de-sn de-st de-th], verbund.effective_states
    assert verbund.covers_state?('de-th')
  end

  test 'Vererbung reicht ueber mehr als eine Ebene und dedupliziert' do
    root = create(:state_association, states: %w[de-be])
    mid = create(:state_association, parent: root, states: %w[de-be de-bb])
    create(:state_association, parent: mid, states: %w[de-mv])

    assert_equal %w[de-bb de-be de-mv], root.effective_states
  end

  test 'Kind erbt nichts vom uebergeordneten Verband' do
    # Gegenrichtung zu allen effective_*-Methoden am Modell: der Spielverbund
    # betreut den Bereich seiner Kinder mit, ein Kind aber nicht den der
    # Geschwister.
    verbund = create(:state_association, states: %w[de-sn])
    kind = create(:state_association, parent: verbund, states: %w[de-st])

    assert_equal %w[de-st], kind.effective_states
    assert_not kind.covers_state?('de-sn')
  end

  test 'Ringverweis im Bestand laeuft nicht endlos' do
    # parent_must_not_create_cycle haelt das aus neuen Daten heraus, aber
    # effective_states haengt an einer Berechtigungspruefung und darf an einem
    # Altbestand nicht haengenbleiben.
    a = create(:state_association, states: %w[de-nw])
    b = create(:state_association, parent: a, states: %w[de-he])
    a.update_column(:parent_id, b.id)

    assert_equal %w[de-he de-nw], a.reload.effective_states
  end

  test 'covers_state? ohne Bundesland ist nie zustaendig' do
    # Spielorte ohne brauchbare PLZ haben kein Bundesland. Sie duerfen nicht
    # jedem Verband zufallen, sondern bleiben beim Bundesverband.
    sa = create(:state_association, states: ApplicationRecord.german_states)

    assert_not sa.covers_state?(nil)
    assert_not sa.covers_state?('')
  end

  test 'full_hash liefert eigene und geerbte Bundeslaender' do
    verbund = create(:state_association, states: %w[de-sn])
    create(:state_association, parent: verbund, states: %w[de-th])

    hash = verbund.full_hash

    assert_equal %w[de-sn], hash[:states]
    assert_equal %w[de-sn de-th], hash[:effective_states]
  end
end
