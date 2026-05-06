class CreateRefereeAssignments < ActiveRecord::Migration[7.0]
  def change
    create_table :referee_assignments do |t|
      t.references :game, null: false, foreign_key: true, index: false
      t.integer :referee1_id
      t.integer :referee2_id
      t.string :status, null: false, default: 'tentative'
      t.datetime :notified_tentative_at
      t.datetime :published_at
      t.bigint :created_by
      t.bigint :updated_by
      t.timestamps
    end

    add_index :referee_assignments, :game_id, unique: true
    add_foreign_key :referee_assignments, :referees, column: :referee1_id
    add_foreign_key :referee_assignments, :referees, column: :referee2_id
  end
end
