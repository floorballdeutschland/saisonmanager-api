class CreateLicenseFeeCalculations < ActiveRecord::Migration[5.1]
  def change
    create_table :referee_calculations do |t|
      t.integer :user_id
      t.datetime :started_at
      t.string :filename_json
      t.string :filename_csv
      t.string :filename_xls
      t.integer :current_dataset
      t.integer :season_id
      t.float :percent

      t.timestamps
    end
  end
end
