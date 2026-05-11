class AddSpecialEventStringToGames < ActiveRecord::Migration[7.0]
  def change
    add_column :games, :special_event_string, :text
  end
end
