class AddChecklistOutcomeToGameDayRefereeConfirmations < ActiveRecord::Migration[7.0]
  def change
    add_column :game_day_referee_confirmations, :properly_conducted, :boolean, null: false, default: true
    add_column :game_day_referee_confirmations, :checklist_answers, :jsonb, null: false, default: []
  end
end
