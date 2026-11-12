# Links zum (erstmaligen) Setzen des Passworts: Statt des Tokens im Klartext
# steht nur noch sein SHA256-Digest in der Datenbank, dazu ein Ablaufzeitpunkt.
# Wer die Datenbank lesen kann, kann damit keine Konten mehr übernehmen.
#
# Die Klartextspalte fällt weg. Offene Links werden dadurch ungültig; sie lassen
# sich über „Passwort vergessen" neu anfordern.
class HashPasswordResetTokens < ActiveRecord::Migration[7.2]
  def up
    add_column :users, :password_reset_token_digest, :string
    add_column :users, :password_reset_expires_at, :datetime
    add_index :users, :password_reset_token_digest, unique: true
    remove_column :users, :password_reset_token
  end

  def down
    add_column :users, :password_reset_token, :string
    remove_index :users, :password_reset_token_digest
    remove_column :users, :password_reset_expires_at
    remove_column :users, :password_reset_token_digest
  end
end
