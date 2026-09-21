# frozen_string_literal: true

# Der YouTube-Zugang des Livestream-Waechters, damit er sich ueber die
# Oberflaeche erneuern laesst statt ueber eine Zeile in der `.env` des Servers.
#
# Der Refresh-Token liegt VERSCHLUESSELT in der Spalte, mit einem Schluessel aus
# `YOUTUBE_TOKEN_KEY`. Der Grund ist die Staging-Kopie: `.dev` traegt einen
# 1:1-Klon der Produktionsdatenbank, und ein dort lesbarer Token beendete echte
# Uebertragungen des Verbandskanals. Auf Staging fehlt die Variable, damit ist
# die Zeile dort nur noch Beiwerk.
class CreateStreamCredentials < ActiveRecord::Migration[7.2]
  def change
    create_table :stream_credentials do |t|
      t.text :refresh_token_ciphertext
      t.string :channel_id
      t.string :channel_title
      t.string :scope
      t.datetime :connected_at
      t.integer :connected_by_user_id

      t.timestamps
    end
  end
end
