class AddMergedIntoIdToPlayers < ActiveRecord::Migration[7.0]
  def change
    add_column :players, :merged_into_id, :integer
    add_foreign_key :players, :players, column: :merged_into_id
  end
end
