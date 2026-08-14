# Zusätzliche Empfänger der Vereinspost, ausgewählt aus den Vereinsmanagern
# des Vereins.
#
# Bewusst ein Integer-Array am Verein und keine Einstellung am Benutzer: Der
# Verein soll an einer Stelle sehen, wer seine Post bekommt. Eine Einstellung
# im fremden Benutzerprofil wäre für ihn unsichtbar, und die Vereinspost ist
# keine Info-Post, sondern trägt Fristen (Transferanfragen,
# Checklisten-Einsprüche, geänderte Ansetzungen).
#
# Die Liste wird beim Versand gegen die aktuellen Rechte aufgelöst
# (Club#notify_manager_emails), veraltet also nicht, wenn jemand die Rolle
# verliert.
class AddNotifyUserIdsToClubs < ActiveRecord::Migration[7.1]
  def change
    add_column :clubs, :notify_user_ids, :integer, array: true, default: [], null: false
  end
end
