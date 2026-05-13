class CreateOnlineTests < ActiveRecord::Migration[7.0]
  def change
    create_table :online_tests do |t|
      t.string :name, null: false
      t.string :lizenzstufe
      t.integer :time_limit_minutes
      t.integer :max_attempts, null: false, default: 2
      t.integer :pass_threshold_points
      t.datetime :deadline
      t.string :status, null: false, default: 'draft'
      t.bigint :created_by

      t.timestamps
    end

    create_table :online_test_questions do |t|
      t.references :online_test, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.text :scenario, null: false
      t.jsonb :rows, null: false, default: []
      t.jsonb :solution, null: false, default: []

      t.timestamps
    end

    add_index :online_test_questions, %i[online_test_id position]

    create_table :online_test_assignments do |t|
      t.references :online_test, null: false, foreign_key: true
      t.references :referee, null: false, foreign_key: true
      t.bigint :assigned_by
      t.datetime :assigned_at, null: false

      t.timestamps
    end

    add_index :online_test_assignments, %i[online_test_id referee_id], unique: true

    create_table :online_test_attempts do |t|
      t.references :online_test, null: false, foreign_key: true
      t.references :referee, null: false, foreign_key: true
      t.integer :attempt_number, null: false
      t.string :status, null: false, default: 'in_progress'
      t.jsonb :answers, null: false, default: []
      t.integer :error_points
      t.datetime :started_at, null: false
      t.datetime :completed_at

      t.timestamps
    end

    add_index :online_test_attempts, %i[online_test_id referee_id attempt_number], unique: true,
              name: 'idx_online_test_attempts_unique'
  end
end
