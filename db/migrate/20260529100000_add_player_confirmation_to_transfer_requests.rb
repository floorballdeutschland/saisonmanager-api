class AddPlayerConfirmationToTransferRequests < ActiveRecord::Migration[7.0]
  def change
    add_column :transfer_requests, :player_confirmation_token, :string
    add_column :transfer_requests, :player_approved_at, :datetime
    add_column :transfer_requests, :player_rejected_at, :datetime

    add_index :transfer_requests, :player_confirmation_token, unique: true
  end
end
