# Selbstständige E-Mail-Änderung mit Bestätigungsprozess (Double-Opt-In):
# Die neue Adresse wird als pending_email vorgemerkt und erst nach Klick auf
# den per Mail verschickten Bestätigungslink (24h gültig) in email übernommen.
# Gespeichert wird nur der SHA256-Digest des Tokens, nie das Token selbst.
class AddEmailChangeConfirmationToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :pending_email, :string
    add_column :users, :email_confirmation_token_digest, :string
    add_column :users, :email_confirmation_expires_at, :datetime
    add_index :users, :email_confirmation_token_digest,
              where: 'email_confirmation_token_digest IS NOT NULL',
              name: 'index_users_on_email_confirmation_token_digest'
  end
end
