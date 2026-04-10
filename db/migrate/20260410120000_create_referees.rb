class CreateReferees < ActiveRecord::Migration[7.0]
  def change
    create_table :referees do |t|
      t.integer  :lizenznummer, null: false
      t.string   :vorname,      null: false
      t.string   :nachname,     null: false
      t.date     :geburtsdatum
      t.string   :email
      t.string   :verein
      t.string   :landesverband
      t.integer  :game_operation_id
      t.string   :lizenzstufe
      t.date     :gueltigkeit
      t.string   :zusatzqualifikation
      t.date     :gueltigkeit_z

      t.timestamps
    end

    add_index :referees, :lizenznummer, unique: true
    add_index :referees, :game_operation_id
  end
end
