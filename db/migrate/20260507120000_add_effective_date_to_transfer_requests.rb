class AddEffectiveDateToTransferRequests < ActiveRecord::Migration[7.0]
  def change
    add_column :transfer_requests, :effective_date, :date
  end
end
