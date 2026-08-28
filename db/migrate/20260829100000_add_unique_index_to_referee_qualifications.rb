# Eine Zusatzqualifikation gibt es je Schiedsrichter genau einmal; die zweite
# Zeile wäre keine zweite Qualifikation, sondern ein zweites Ablaufdatum für
# dieselbe. Bisher hielt das allein die Modell-Validierung zusammen, und die
# greift nur, wo über das Modell geschrieben wird — die Zusammenführung zweier
# Schiedsrichterprofile schiebt die Qualifikationen dagegen mit `update_all`
# um, also an jeder Validierung vorbei. Seit der Stufenfilter die
# Qualifikationen mitliest, verdoppelt eine Dublette zudem die Zeile in der
# Trefferliste. Deshalb steht die Regel jetzt in der Datenbank, wie schon bei
# `referee_taggings`.
#
# Vorhandene Dubletten würden den Index scheitern lassen. Statt sie
# stillschweigend zu verwerfen, bricht die Migration vorher mit den betroffenen
# Paaren ab: Welche der beiden Zeilen die richtige ist, entscheidet das
# Ablaufdatum und nicht der Zufall, und das gehört von Hand geprüft. Auf dem
# bekannten Bestand kann es keine geben — der einzige schreibende Weg in der
# Anwendung löscht die Qualifikationen vor dem Neuanlegen und legt sie
# validiert an, und die Erstbefüllung aus `zusatzqualifikation` lieferte je
# Schiedsrichter höchstens eine Zeile.
class AddUniqueIndexToRefereeQualifications < ActiveRecord::Migration[7.2]
  INDEX_NAME = 'index_referee_qualifications_on_referee_and_type'.freeze

  def up
    duplicates = select_rows(<<~SQL.squish)
      SELECT referee_id, referee_qualification_type_id, COUNT(*)
      FROM referee_qualifications
      GROUP BY referee_id, referee_qualification_type_id
      HAVING COUNT(*) > 1
      ORDER BY referee_id
    SQL

    if duplicates.any?
      raise "referee_qualifications enthaelt #{duplicates.size} doppelte " \
            '(referee_id, referee_qualification_type_id)-Paare. Sie muessen vor ' \
            'dieser Migration von Hand bereinigt werden (massgeblich ist das ' \
            "spaetere valid_until): #{duplicates.map { |r| r.first(2).join('/') }.join(', ')}"
    end

    add_index :referee_qualifications, %i[referee_id referee_qualification_type_id],
              unique: true, name: INDEX_NAME
  end

  def down
    remove_index :referee_qualifications, name: INDEX_NAME
  end
end
