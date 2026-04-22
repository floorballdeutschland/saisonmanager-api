class AddLastUsedAtToApiKeys < ActiveRecord::Migration[7.0]
  def change
    add_column :api_keys, :last_used_at, :datetime
  end
end
