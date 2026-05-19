class CreatePlayerChangeRequests < ActiveRecord::Migration[7.0]
  def change
    create_table :player_change_requests do |t|
      t.references :player, null: false, foreign_key: true
      t.integer :club_id, null: false
      t.integer :requested_by_user_id, null: false
      t.integer :reviewed_by_user_id
      t.string :correction_type, null: false
      t.string :new_value
      t.string :status, null: false, default: 'pending'
      t.text :rejection_reason

      t.timestamps
    end

    add_index :player_change_requests, :club_id
    add_index :player_change_requests, :status
  end
end
