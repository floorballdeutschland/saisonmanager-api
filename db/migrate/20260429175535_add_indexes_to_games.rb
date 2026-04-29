class AddIndexesToGames < ActiveRecord::Migration[7.0]
  def change
    add_index :games, :home_team_id, if_not_exists: true
    add_index :games, :guest_team_id, if_not_exists: true
    add_index :games, :referee_ids, using: :gin, if_not_exists: true
  end
end
