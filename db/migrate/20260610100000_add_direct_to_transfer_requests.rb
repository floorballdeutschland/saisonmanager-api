class AddDirectToTransferRequests < ActiveRecord::Migration[7.0]
  def change
    # Markiert von der SBK direkt durchgeführte Vereinswechsel (ohne den
    # mehrstufigen Genehmigungsprozess) – wichtig u. a. für die Abrechnung.
    add_column :transfer_requests, :direct, :boolean, null: false, default: false
  end
end
