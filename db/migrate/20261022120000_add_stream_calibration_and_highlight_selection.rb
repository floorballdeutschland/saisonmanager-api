# Tabletmodus: Kalibrierung des Stream-Versatzes, Auswahl der Highlight-Szenen
# und vorgemerkte Szenen (fe#560).
#
# - `stream_broadcasts.offset_seconds`: um wie viele Sekunden das Bild der
#   Aufzeichnung hinter der Hallenzeit liegt. NULL heißt "nicht kalibriert",
#   nicht 0: Unkalibriert bleiben die bisherigen, großzügigeren Szenenfenster.
# - `game_shots.in_highlights`: je Szene (Tor-Schuss oder vorgemerkte Szene)
#   die Auswahl für die öffentlichen Highlights, Standard an.
# - `game_shots.kind = 'mark'`: "Szene vormerken" ohne Team und Position. Team
#   und Position werden deshalb nullbar; das Modell verlangt sie weiter für
#   Schüsse und Freischläge.
# - `tablet_highlight_requests`: "Link zum Kalibrieren schicken", gestellt beim
#   Beenden des Tabletmodus, verschickt vom Wächter, sobald die Aufzeichnung
#   fertig ist.
class AddStreamCalibrationAndHighlightSelection < ActiveRecord::Migration[7.2]
  def change
    change_table :stream_broadcasts, bulk: true do |t|
      t.integer :offset_seconds,
                comment: 'Versatz Bild zu Hallenzeit in s (positiv: Bild liegt dahinter); NULL = nicht kalibriert'
      t.datetime :calibrated_at
      t.bigint :calibrated_by_user_id, comment: 'NULL bei Kalibrierung über den Mail-Link'
      t.string :calibrated_via, comment: 'link / user'
    end

    add_column :game_shots, :in_highlights, :boolean, null: false, default: true,
                                                      comment: 'Szene erscheint in den öffentlichen Highlights'
    change_column_null :game_shots, :team, true
    change_column_null :game_shots, :x, true
    change_column_null :game_shots, :y, true
    change_column_comment :game_shots, :kind, from: 'shot / free_hit', to: 'shot / free_hit / mark'

    create_table :tablet_highlight_requests do |t|
      t.references :game, null: false, foreign_key: true
      t.bigint :user_id, comment: 'Angemeldet: Mail an die Kontoadresse, keine Adresse gespeichert'
      t.string :email, comment: 'Eingegebene Adresse, nach dem Versand gelöscht'
      t.string :token_digest, comment: 'SHA256 des Links, erst beim Versand erzeugt'
      t.datetime :sent_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :tablet_highlight_requests, :token_digest, unique: true
    add_index :tablet_highlight_requests, :sent_at
  end
end
