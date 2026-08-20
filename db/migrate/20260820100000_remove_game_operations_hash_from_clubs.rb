# Entfernt `clubs.game_operations_hash`.
#
# Die Spalte trug die Zuständigkeit für einen Verein als Heimat-Eintrag
# (`home_game_operation: true`) und, bis Release 1.78, zusätzlich Gast-Einträge
# auf fremde Spielbetriebe aus dem Altdaten-Import 2010–2014.
#
# Seit 1.90.0 leitet `Club#main_game_operation_id` die Zuständigkeit aus dem
# Landesverband ab. Die Spalte entscheidet damit über nichts mehr; sie blieb nur
# stehen, damit `clubs:responsibility_report` den Umzug gegenprüfen konnte. Der
# Datenlauf ist auf Staging und Produktion durch (Bericht: genau ein gewollter
# Wechsel, kein Verein ohne Zuständigkeit), der Bericht entfällt mit dieser
# Migration.
#
# Mit der Spalte verschwindet auch die Möglichkeit, einem Verein einen ZWEITEN
# Spielbetrieb zu geben. Die Gast-Einträge waren keine eigene Spalte, sondern
# weitere Objekte im selben Array, und eine Oberfläche zum Eintragen gab es nie.
# Nach dieser Migration ist ein zweiter Spielbetrieb strukturell nicht mehr
# darstellbar. Wer fremde Vereine lesen muss, bekommt eine Vereins-Freigabe
# (StateAssociationRelease); wer eine Gastmannschaft betreut, ist über die Liga
# zuständig.
#
# Irreversibel: Der Inhalt ließe sich aus dem Landesverband zwar wieder
# herstellen, aber nur in der Form, die diese Umstellung gerade beseitigt hat –
# ein `down`, das die Altlast neu erzeugt, wäre schlimmer als keins.
class RemoveGameOperationsHashFromClubs < ActiveRecord::Migration[7.2]
  def up
    remove_column :clubs, :game_operations_hash
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
