class AddNominatedRefereeIdsToGames < ActiveRecord::Migration[7.0]
  def change
    add_column :games, :nominated_referee_ids, :integer, array: true, default: []
  end
end
