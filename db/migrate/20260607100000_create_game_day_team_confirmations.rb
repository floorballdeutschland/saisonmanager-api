class CreateGameDayTeamConfirmations < ActiveRecord::Migration[7.0]
  def change
    create_table :game_day_team_confirmations do |t|
      t.references :game_day, null: false, foreign_key: true
      t.references :team, null: false, foreign_key: true
      t.datetime :confirmed_at, null: false
      t.boolean :properly_conducted, null: false, default: true
      t.jsonb :checklist_answers, null: false, default: []
      # Welcher Benutzer (TM/VM) die Bestätigung abgegeben hat – nur zur
      # Nachvollziehbarkeit, ohne FK (Benutzer können gelöscht werden).
      t.bigint :confirmed_by_user_id
      t.timestamps
    end

    add_index :game_day_team_confirmations, %i[game_day_id team_id],
              unique: true,
              name: 'index_game_day_team_confirmations_unique'
  end
end
