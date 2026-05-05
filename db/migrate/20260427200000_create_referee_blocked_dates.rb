class CreateRefereeBlockedDates < ActiveRecord::Migration[7.0]
  def change
    create_table :referee_blocked_dates do |t|
      t.references :referee, null: false, foreign_key: true
      t.date :date, null: false
      t.timestamps
    end

    add_index :referee_blocked_dates, [:referee_id, :date], unique: true
  end
end
