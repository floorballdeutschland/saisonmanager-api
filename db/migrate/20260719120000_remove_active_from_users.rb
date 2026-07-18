class RemoveActiveFromUsers < ActiveRecord::Migration[7.1]
  # Das Boolean-Flag ist seit der Konto-Archivierung (archived_at/archived_by,
  # Release 1.53.0) vollständig verwaist: Admin-Toggle, user_json-Ausgabe und
  # der letzte lesende Zugriff (RefereeFeedbackNotifier) wurden entfernt.
  # Historisch hat es den Login nie gesperrt, sondern nur Info-Mails
  # unterdrückt und ein Badge in der Benutzerliste gefärbt.
  def change
    remove_column :users, :active, :boolean, default: true
  end
end
