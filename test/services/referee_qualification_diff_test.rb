require 'test_helper'

# Entscheidet, wann die Qualifikationsmail rausgeht. Die Zuordnungen werden beim
# Speichern komplett neu gesetzt (destroy_all + create), Dirty-Tracking gibt es
# also nicht – ohne diesen Vergleich löste jedes Speichern der Schiri-Maske eine
# Mail aus.
class RefereeQualificationDiffTest < ActiveSupport::TestCase
  def setup
    @coach = RefereeQualificationType.create!(name: "B-Coach #{SecureRandom.hex(3)}")
    @beob  = RefereeQualificationType.create!(name: "Beobachter #{SecureRandom.hex(3)}")
  end

  test 'meldet eine neu ergaenzte Qualifikation' do
    changes = RefereeQualificationDiff.changes(
      before: {}, after: { @coach.id => Date.new(2027, 6, 30) }
    )

    assert_equal 1, changes.size
    assert_equal @coach.name, changes.first[:name]
    assert_equal :added, changes.first[:kind]
    assert_equal Date.new(2027, 6, 30), changes.first[:valid_until]
  end

  test 'meldet eine geaenderte Gueltigkeit als Aktualisierung' do
    changes = RefereeQualificationDiff.changes(
      before: { @coach.id => Date.new(2026, 6, 30) },
      after:  { @coach.id => Date.new(2027, 6, 30) }
    )

    kinds = changes.map { |change| change[:kind] }
    assert_equal [:updated], kinds
  end

  test 'meldet unveraenderte Qualifikationen nicht' do
    bestand = { @coach.id => Date.new(2027, 6, 30), @beob.id => nil }

    assert_empty RefereeQualificationDiff.changes(before: bestand, after: bestand)
  end

  test 'meldet einen Wegfall nicht' do
    changes = RefereeQualificationDiff.changes(
      before: { @coach.id => nil, @beob.id => nil }, after: { @coach.id => nil }
    )

    assert_empty changes
  end

  # Ein Ablaufdatum zu entfernen ist eine Aenderung, nicht ein Wegfall: Die
  # Qualifikation bleibt, sie gilt jetzt unbefristet.
  test 'meldet ein entferntes Ablaufdatum als Aktualisierung' do
    changes = RefereeQualificationDiff.changes(
      before: { @coach.id => Date.new(2026, 6, 30) }, after: { @coach.id => nil }
    )

    kinds = changes.map { |change| change[:kind] }
    assert_equal [:updated], kinds
    assert_nil changes.first[:valid_until]
  end

  # Eingabe in umgekehrter Reihenfolge, damit ein Wegfall der Sortierung auffaellt.
  # „B-Coach" vor „Beobachter", weil '-' vor 'e' sortiert.
  test 'sortiert mehrere Aenderungen nach Name' do
    changes = RefereeQualificationDiff.changes(
      before: {}, after: { @beob.id => nil, @coach.id => nil }
    )

    namen = changes.map { |change| change[:name] }
    assert_equal [@coach.name, @beob.name], namen
  end

  # Strukturell unerreichbar (der Verweis auf den Typ ist Pflicht), aber wenn es
  # doch passiert, darf keine Mail ueber eine namenlose Qualifikation rausgehen.
  test 'ueberspringt einen unbekannten Qualifikationstyp' do
    changes = RefereeQualificationDiff.changes(
      before: {}, after: { @coach.id => nil, 999_999 => nil }
    )

    namen = changes.map { |change| change[:name] }
    assert_equal [@coach.name], namen
  end
end
