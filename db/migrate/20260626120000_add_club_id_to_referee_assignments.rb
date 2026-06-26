class AddClubIdToRefereeAssignments < ActiveRecord::Migration[7.1]
  def change
    add_column :referee_assignments, :club_id, :integer
    add_index :referee_assignments, :club_id
  end
end
