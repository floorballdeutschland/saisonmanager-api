class AddScanRequiredToGameOperations < ActiveRecord::Migration[7.1]
  def change
    add_column :game_operations, :scan_required, :boolean, default: false, null: false
  end
end
