class CreateGameDayOverlayLinks < ActiveRecord::Migration[7.0]
  def change
    create_table :game_day_overlay_links do |t|
      t.references :game_day, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      # Steuerzustand der Einblendungen (welche Bauchbinde, Uhr, Vollbild).
      # Liegt am Link und nicht am Spiel: Er gehört zur Übertragung, nicht zum
      # Spielbericht, und überlebt so das Neuladen einer Browser-Quelle in OBS.
      t.jsonb :state, null: false, default: {}
      t.datetime :state_updated_at
      t.timestamps
    end

    add_index :game_day_overlay_links, :token_digest, unique: true
  end
end
