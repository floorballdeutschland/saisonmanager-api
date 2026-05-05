class CreateGameDaySecretaryLinks < ActiveRecord::Migration[7.0]
  def change
    create_table :game_day_secretary_links do |t|
      t.references :game_day, null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :game_day_secretary_links, :token_digest, unique: true
  end
end
