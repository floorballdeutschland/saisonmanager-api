# frozen_string_literal: true

# Genau EINE Zeile, und zwar erzwungen.
#
# Der Entwurf geht von einem einzigen Verbandskanal aus, `StreamCredential.current`
# war aber schlicht `first`. Druecken zwei Admins gleichzeitig auf „Verbinden",
# entstuenden zwei Zeilen -- die Oberflaeche meldete den neuen Kanal, waehrend
# der Waechter weiter den alten Token benutzte und ein spaeteres Trennen nur die
# alte Zeile widerriefe. Der eindeutige Index macht das unmoeglich.
class AddSingletonToStreamCredentials < ActiveRecord::Migration[7.2]
  def up
    add_column :stream_credentials, :singleton, :integer, default: 0, null: false

    # Sollte es wider Erwarten schon mehrere geben, bleibt die juengste stehen:
    # Sie traegt den zuletzt verbundenen Zugang.
    execute <<~SQL.squish
      DELETE FROM stream_credentials
      WHERE id NOT IN (SELECT MAX(id) FROM stream_credentials)
    SQL

    add_index :stream_credentials, :singleton, unique: true
  end

  def down
    remove_index :stream_credentials, :singleton
    remove_column :stream_credentials, :singleton
  end
end
