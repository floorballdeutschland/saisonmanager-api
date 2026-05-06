class CreateGameRefereeReports < ActiveRecord::Migration[7.0]
  def change
    create_table :game_referee_reports do |t|
      t.references :game, null: false, foreign_key: true, index: false
      t.references :uploaded_by, foreign_key: { to_table: :users }, null: false
      t.timestamps
    end
    add_index :game_referee_reports, :game_id, unique: true
  end
end
