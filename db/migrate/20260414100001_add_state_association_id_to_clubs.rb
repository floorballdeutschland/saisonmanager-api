class AddStateAssociationIdToClubs < ActiveRecord::Migration[7.0]
  def change
    add_column :clubs, :state_association_id, :integer
  end
end
