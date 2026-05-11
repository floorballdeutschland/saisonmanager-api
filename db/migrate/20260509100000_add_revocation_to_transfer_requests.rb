class AddRevocationToTransferRequests < ActiveRecord::Migration[7.0]
  def change
    add_column :transfer_requests, :revoked_by, :integer
    add_column :transfer_requests, :revoked_at, :datetime
    add_column :transfer_requests, :revocation_reason, :text
  end
end
