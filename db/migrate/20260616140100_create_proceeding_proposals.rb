class CreateProceedingProposals < ActiveRecord::Migration[7.1]
  def change
    create_table :proceeding_proposals do |t|
      t.bigint :game_id, null: false
      t.bigint :state_association_id, null: false
      t.string :status, null: false, default: 'pending', comment: 'pending | rejected | opened'
      t.bigint :created_by_id, comment: 'uploadender Schiri/User; ohne FK, User können gelöscht werden'
      t.bigint :decided_by_id
      t.datetime :decided_at
      t.timestamps
    end

    add_index :proceeding_proposals, :game_id, unique: true
    add_index :proceeding_proposals, :state_association_id
    add_index :proceeding_proposals, :status
  end
end
