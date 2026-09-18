class AddTeamConfirmationNotifiedAtToGameDays < ActiveRecord::Migration[7.2]
  def change
    add_column :game_days, :team_confirmation_notified_at, :datetime
  end
end
