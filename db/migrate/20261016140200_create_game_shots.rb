# Tabletmodus (api#816, fe#344): Schüsse mit Position, Ergebnis und dem
# Zeitpunkt des ersten Antippens.
#
# Eigene Tabelle statt eines weiteren JSONB-Arrays an `games`: 60 bis 80 Schüsse
# je Spiel von einem zweiten Gerät neben dem Sekretariat, gepuffert und nach
# einem Verbindungsabbruch nachgereicht. Ein Read-Modify-Write auf einem Array
# verträgt das schlecht, `client_uuid` macht das Nachreichen idempotent.
class CreateGameShots < ActiveRecord::Migration[7.2]
  def change
    create_table :game_shots do |t|
      t.references :game, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :client_uuid, null: false, comment: 'Vom Tablet vergeben, macht das Nachreichen idempotent'
      t.string :team, null: false, comment: 'home / guest: das schießende Team'
      t.integer :period, null: false
      t.string :game_time, comment: 'Spielzeit m:ss wie bei den Ereignissen'
      t.datetime :tapped_at, null: false,
                             comment: 'Erstes Antippen, Serverzeit (um die Abweichung der Geräteuhr korrigiert)'
      t.decimal :x, precision: 6, scale: 5, null: false,
                    comment: 'Ganzes Feld Bande zu Bande: 0 hinter dem eigenen Tor, 1 hinter dem gegnerischen (Angriffsrichtung)'
      t.decimal :y, precision: 6, scale: 5, null: false, comment: '0 linke, 1 rechte Seitenbande aus Sicht des Angreifers'
      t.string :result, null: false, comment: 'goal / saved / missed / blocked'
      t.bigint :shooter_player_id
      t.bigint :goalkeeper_player_id, comment: 'Torhüter des verteidigenden Teams'
      t.integer :event_id, comment: 'id des verknüpften Tores in games.events'
      t.integer :created_by
      t.timestamps
    end
    add_index :game_shots, :client_uuid, unique: true
    add_index :game_shots, %i[game_id tapped_at]

    change_table :games, bulk: true do |t|
      t.datetime :tablet_capture_at, comment: 'Erster im Tabletmodus erfasster Schuss'
      t.boolean :tablet_shots_complete, comment: 'Beim Abschluss erfragt: Schüsse vollständig erfasst?'
    end
  end
end
