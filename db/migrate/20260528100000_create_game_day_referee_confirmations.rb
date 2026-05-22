class CreateGameDayRefereeConfirmations < ActiveRecord::Migration[7.0]
  def change
    create_table :game_day_referee_confirmations do |t|
      t.references :game_day, null: false, foreign_key: true
      t.references :referee, null: false, foreign_key: true
      t.datetime :confirmed_at, null: false
      t.timestamps
    end

    add_index :game_day_referee_confirmations, %i[game_day_id referee_id],
              unique: true,
              name: 'index_game_day_referee_confirmations_unique'
  end
end
