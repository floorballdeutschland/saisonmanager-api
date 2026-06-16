class AddHostNotifiedAtToGameDays < ActiveRecord::Migration[7.1]
  def change
    add_column :game_days, :host_notified_at, :datetime
  end
end
