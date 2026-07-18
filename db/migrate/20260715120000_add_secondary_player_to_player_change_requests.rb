class AddSecondaryPlayerToPlayerChangeRequests < ActiveRecord::Migration[7.1]
  def change
    add_column :player_change_requests, :secondary_player_id, :bigint
    add_index :player_change_requests, :secondary_player_id
    add_foreign_key :player_change_requests, :players, column: :secondary_player_id
  end
end
