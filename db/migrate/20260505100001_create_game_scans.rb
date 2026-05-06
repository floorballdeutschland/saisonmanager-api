class CreateGameScans < ActiveRecord::Migration[7.1]
  def change
    create_table :game_scans do |t|
      t.references :game, null: false, foreign_key: true
      t.references :uploaded_by, foreign_key: { to_table: :users }, null: true
      t.datetime :expires_at, null: false
      t.timestamps
    end
  end
end
