class CreateApiKeys < ActiveRecord::Migration[7.0]
  def change
    create_table :api_keys do |t|
      t.string :name, null: false
      t.string :key_digest, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end

    add_index :api_keys, :key_digest, unique: true
  end
end
