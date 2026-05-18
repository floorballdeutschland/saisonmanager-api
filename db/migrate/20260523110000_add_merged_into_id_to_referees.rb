class AddMergedIntoIdToReferees < ActiveRecord::Migration[7.0]
  def change
    add_column :referees, :merged_into_id, :integer
    add_foreign_key :referees, :referees, column: :merged_into_id
  end
end
