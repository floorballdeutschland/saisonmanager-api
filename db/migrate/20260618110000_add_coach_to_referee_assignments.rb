class AddCoachToRefereeAssignments < ActiveRecord::Migration[7.1]
  def change
    add_column :referee_assignments, :coach_id, :integer
    add_index :referee_assignments, :coach_id
  end
end
