class AddChecklistAnswersToGames < ActiveRecord::Migration[7.0]
  def change
    add_column :games, :checklist_answers, :jsonb, default: []
  end
end
