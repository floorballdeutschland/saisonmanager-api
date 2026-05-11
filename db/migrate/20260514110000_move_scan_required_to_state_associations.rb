class MoveScanRequiredToStateAssociations < ActiveRecord::Migration[7.0]
  def change
    add_column :state_associations, :scan_required, :boolean, default: false, null: false

    reversible do |dir|
      dir.up do
        # Propagate existing scan_required=true from game_operations to their state_association,
        # but only if state_association_id already exists (added by a separate migration).
        if column_exists?(:game_operations, :state_association_id)
          execute <<~SQL
            UPDATE state_associations sa
            SET scan_required = true
            FROM game_operations go
            WHERE go.state_association_id = sa.id
              AND go.scan_required = true
          SQL
        end
      end
    end

    remove_column :game_operations, :scan_required, :boolean, default: false, null: false
  end
end
