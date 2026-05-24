class WidenTransferRequestActiveIndex < ActiveRecord::Migration[7.0]
  def up
    remove_index :transfer_requests, name: 'index_transfer_requests_on_player_id_active'

    add_index :transfer_requests, :player_id,
              unique: true,
              where: "status IN ('pending_club', 'pending_player', 'pending_lv', 'scheduled')",
              name: 'index_transfer_requests_on_player_id_active'
  end

  def down
    remove_index :transfer_requests, name: 'index_transfer_requests_on_player_id_active'

    add_index :transfer_requests, :player_id,
              unique: true,
              where: "status IN ('pending_club', 'pending_lv')",
              name: 'index_transfer_requests_on_player_id_active'
  end
end
