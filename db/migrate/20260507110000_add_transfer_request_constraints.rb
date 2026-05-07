class AddTransferRequestConstraints < ActiveRecord::Migration[7.0]
  def change
    add_index :transfer_requests, :player_id,
              unique: true,
              where: "status IN ('pending_club', 'pending_lv')",
              name: 'index_transfer_requests_on_player_id_active'

    add_foreign_key :transfer_requests, :players
    add_foreign_key :transfer_requests, :clubs, column: :requesting_club_id
    add_foreign_key :transfer_requests, :clubs, column: :former_club_id
  end
end
