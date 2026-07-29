class CreateRefereeFeedbackInvitations < ActiveRecord::Migration[7.1]
  def change
    create_table :referee_feedback_invitations do |t|
      t.bigint :game_id, null: false
      t.bigint :team_id, null: false
      t.bigint :player_id
      t.string :email, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at

      t.timestamps
    end

    add_index :referee_feedback_invitations, :token_digest, unique: true
    add_index :referee_feedback_invitations, %i[game_id team_id], unique: true
  end
end
