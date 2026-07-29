class AddSubmitterOriginToRefereeFeedbacks < ActiveRecord::Migration[7.1]
  def change
    add_column :referee_feedbacks, :submitted_by_player_id, :bigint
    add_column :referee_feedbacks, :submitted_by_email, :string
  end
end
