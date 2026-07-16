class AddArchivingToUsers < ActiveRecord::Migration[7.0]
  def change
    add_column :users, :archived_at, :datetime
    add_column :users, :archived_by, :bigint
  end
end
