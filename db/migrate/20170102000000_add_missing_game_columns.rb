class AddMissingGameColumns < ActiveRecord::Migration[7.0]
  def change
    add_column :games, :started, :boolean, default: false
    add_column :games, :ended, :boolean, default: false
    add_column :games, :game_ended, :boolean, default: false
  end
end
