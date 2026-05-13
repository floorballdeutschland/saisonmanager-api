class AddRequestTypeToTransferRequests < ActiveRecord::Migration[7.0]
  def change
    add_column :transfer_requests, :request_type, :string, default: 'transfer', null: false
    add_index :transfer_requests, :request_type
  end
end
