# Zeitpunkt, zu dem der letzte Link zum Setzen des Passworts verschickt wurde.
# „Passwort vergessen" stellt innerhalb kurzer Zeit keinen zweiten Link aus,
# weil jeder neue Link den vorigen ungültig macht: Nach einem Doppelklick
# öffneten Nutzer die erste Mail und bekamen „Ungültiger oder abgelaufener
# Link".
class AddPasswordResetSentAtToUsers < ActiveRecord::Migration[7.2]
  def change
    add_column :users, :password_reset_sent_at, :datetime
  end
end
