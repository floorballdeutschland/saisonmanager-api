class AddDeactivatedAtToPlayers < ActiveRecord::Migration[7.0]
  def change
    add_column :players, :deactivated_at, :datetime
    add_column :players, :deactivated_by, :integer
    add_index :players, :deactivated_at
  end
end
