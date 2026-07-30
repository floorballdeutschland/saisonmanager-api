class AddRefereeNotesToGames < ActiveRecord::Migration[7.1]
  def change
    add_column :games, :referee_notes, :text
    add_column :games, :referee_notes_updated_at, :datetime
    add_column :games, :referee_notes_updated_by, :bigint
  end
end
