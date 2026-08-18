# Bundeslaender im Zustaendigkeitsbereich eines Landesverbands. Mehrwertig, weil
# ein Verband mehrere Bundeslaender betreut (FVNB: Niedersachsen und Bremen,
# RLPSAAR: Rheinland-Pfalz und Saarland, FVBB: Berlin und Brandenburg).
#
# Kein Backfill: die Verbaende werden von Hand gepflegt. Solange das Feld leer
# ist, aendert sich nichts – jede Auswertung faellt dann auf den bisherigen Weg
# zurueck (#468).
#
# Bewusst ohne Index: gelesen wird vom Verband zum Bundesland, nicht umgekehrt,
# und die Tabelle bleibt in der Groessenordnung der Landesverbaende.
class AddStatesToStateAssociations < ActiveRecord::Migration[7.1]
  def change
    add_column :state_associations, :states, :string, array: true, default: [], null: false,
                                                      comment: 'Bundeslaender im Zustaendigkeitsbereich (ISO-Kuerzel, z. B. de-nw)'
  end
end
