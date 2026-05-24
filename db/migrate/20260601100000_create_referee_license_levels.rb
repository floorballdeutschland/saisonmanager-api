class CreateRefereeLicenseLevels < ActiveRecord::Migration[7.0]
  def change
    create_table :referee_license_levels do |t|
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      t.integer :position

      t.timestamps
    end

    add_index :referee_license_levels, :name, unique: true
  end
end
