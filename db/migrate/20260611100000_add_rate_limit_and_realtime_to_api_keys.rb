class AddRateLimitAndRealtimeToApiKeys < ActiveRecord::Migration[7.0]
  def up
    add_column :api_keys, :rate_limit, :integer, comment: 'Max requests per minute; nil = unlimited'
    add_column :api_keys, :realtime, :boolean, default: false, null: false

    # All existing keys get realtime access so saisonmanager.org and any
    # already-deployed partner integrations continue to work after rollout.
    # New keys default to realtime: false (safe for third-party partners).
    ApiKey.update_all(realtime: true)
  end

  def down
    remove_column :api_keys, :rate_limit
    remove_column :api_keys, :realtime
  end
end
