class AddDeactivationToClubs < ActiveRecord::Migration[7.0]
  def change
    add_column :clubs, :deactivated_at, :datetime
    add_column :clubs, :deactivated_by, :bigint
  end
end
