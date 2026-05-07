class AddChecklistVetoToGames < ActiveRecord::Migration[7.0]
  def change
    add_column :games, :checklist_veto_token_digest, :string
    add_column :games, :checklist_veto_submitted_at, :datetime
    add_column :games, :checklist_veto_answers, :jsonb, default: []
    add_index :games, :checklist_veto_token_digest, unique: true,
              where: 'checklist_veto_token_digest IS NOT NULL'
  end
end
