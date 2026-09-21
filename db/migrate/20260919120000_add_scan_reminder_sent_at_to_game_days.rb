class AddScanReminderSentAtToGameDays < ActiveRecord::Migration[7.2]
  def change
    add_column :game_days, :scan_reminder_sent_at, :datetime
  end
end
