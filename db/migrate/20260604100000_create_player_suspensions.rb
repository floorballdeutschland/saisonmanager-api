class CreatePlayerSuspensions < ActiveRecord::Migration[7.0]
  def change
    create_table :player_suspensions do |t|
      t.bigint :player_id, null: false
      # NULL = Beantragungssperre (gilt für den gesamten Spieler), gesetzt = Aussetzung einer einzelnen Team-Lizenz
      t.bigint :team_id
      t.date :valid_from, null: false
      t.date :valid_until, null: false
      t.text :reason
      # [{ "license_id" => "...", "previous_status_id" => 1 }, ...] — für exaktes Reaktivieren
      t.jsonb :affected_licenses, null: false, default: []
      t.bigint :created_by
      t.datetime :lifted_at
      t.bigint :lifted_by

      t.timestamps
    end

    add_index :player_suspensions, :player_id
    add_index :player_suspensions, %i[player_id lifted_at]
    add_index :player_suspensions, :valid_until
  end
end
