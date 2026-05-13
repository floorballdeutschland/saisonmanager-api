class AddHierarchyToStateAssociationsAndGameOperations < ActiveRecord::Migration[7.0]
  def change
    add_column :state_associations, :parent_id, :integer
    add_index :state_associations, :parent_id

    add_column :state_associations, :express_license_enabled, :boolean, default: false
    add_column :state_associations, :require_paper_game_report, :boolean, default: false

    add_column :game_operations, :state_association_id, :integer
    add_index :game_operations, :state_association_id
  end
end
