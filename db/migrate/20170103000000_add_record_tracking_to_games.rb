class AddRecordTrackingToGames < ActiveRecord::Migration[7.0]
  def change
    add_column :games, :record_created_at, :datetime
    add_column :games, :record_updated_at, :datetime
    add_column :games, :record_created_by, :bigint
    add_column :games, :record_updated_by, :bigint
  end
end
