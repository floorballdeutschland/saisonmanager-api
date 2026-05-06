class AddUniqueIndexToGameScansGameId < ActiveRecord::Migration[7.1]
  def change
    add_index :game_scans, :game_id, unique: true
  end
end
