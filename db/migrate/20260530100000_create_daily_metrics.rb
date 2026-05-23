class CreateDailyMetrics < ActiveRecord::Migration[7.0]
  def change
    create_table :daily_metrics do |t|
      t.date :date, null: false
      t.string :metric_key, null: false
      t.integer :count, default: 0, null: false
      t.timestamps
    end

    add_index :daily_metrics, [:date, :metric_key], unique: true
  end
end
