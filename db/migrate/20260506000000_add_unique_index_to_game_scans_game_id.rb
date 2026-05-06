class AddUniqueIndexToGameScansGameId < ActiveRecord::Migration[7.0]
  def up
    remove_index :game_scans, :game_id if index_exists?(:game_scans, :game_id)
    add_index :game_scans, :game_id, unique: true
  end

  def down
    remove_index :game_scans, :game_id
    add_index :game_scans, :game_id
  end
end
