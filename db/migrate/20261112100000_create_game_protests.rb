# Protest mit Protestparteien (11.11.2026): Nach dem Haken „Protest" wählt die
# Spielleitung, wer protestiert. Jede Partei außer „Andere" bekommt beim
# Abschluss des Spielberichts einen eigenen Upload-Link für das
# Protestformular, das hier gespeichert wird, statt separat per Mail zu laufen.
class CreateGameProtests < ActiveRecord::Migration[7.2]
  def change
    add_column :games, :protest_parties, :jsonb, null: false, default: [],
                                                 comment: 'Protestparteien: host, home, guest, referees, other'

    create_table :game_protests do |t|
      t.references :game, null: false, foreign_key: true, index: false
      t.string :party, null: false
      t.string :token_digest, null: false
      t.jsonb :recipients, null: false, default: [],
                           comment: 'Adressen, an die der Upload-Link ging (leer = keine Adresse gefunden)'
      t.datetime :invited_at
      t.datetime :submitted_at
      t.timestamps
    end
    add_index :game_protests, %i[game_id party], unique: true
    add_index :game_protests, :token_digest, unique: true
  end
end
