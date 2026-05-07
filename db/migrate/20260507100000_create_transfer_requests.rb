class CreateTransferRequests < ActiveRecord::Migration[7.0]
  def change
    create_table :transfer_requests do |t|
      t.bigint :player_id, null: false
      t.bigint :requesting_club_id, null: false
      t.bigint :former_club_id, null: false
      t.string :status, null: false, default: 'pending_club'
      t.integer :created_by, null: false
      t.integer :approved_by_club_user_id
      t.datetime :club_approved_at
      t.integer :approved_by_lv_user_id
      t.datetime :lv_approved_at
      t.integer :rejected_by
      t.datetime :rejected_at
      t.text :rejection_reason
      t.integer :season_id, null: false

      t.timestamps
    end

    add_index :transfer_requests, :player_id
    add_index :transfer_requests, :requesting_club_id
    add_index :transfer_requests, :former_club_id
    add_index :transfer_requests, :status
  end
end
