class CreateMergeLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :merge_logs do |t|
      t.string :object_type, null: false # 'player' | 'arena' | 'referee'
      t.bigint :master_id, null: false
      t.string :master_label
      t.bigint :merged_id, null: false
      t.string :merged_label
      # Ausführender Benutzer – ohne FK, da Benutzer gelöscht werden können.
      t.bigint :performed_by_user_id
      t.timestamps
    end

    add_index :merge_logs, :created_at
    add_index :merge_logs, :object_type
  end
end
