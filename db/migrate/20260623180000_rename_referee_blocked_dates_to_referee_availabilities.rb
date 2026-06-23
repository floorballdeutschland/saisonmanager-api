class RenameRefereeBlockedDatesToRefereeAvailabilities < ActiveRecord::Migration[7.1]
  # Die Logik wird umgedreht: Schiedsrichter*innen hinterlegen nicht mehr ihre
  # Sperrtermine, sondern aktiv ihre Verfügbarkeiten. Die Altdaten (Sperrtermine)
  # haben in der neuen Bedeutung keinen Sinn und werden bewusst verworfen –
  # deshalb Tabelle neu aufbauen statt umbenennen.
  def up
    drop_table :referee_blocked_dates, if_exists: true

    create_table :referee_availabilities do |t|
      t.references :referee, null: false, foreign_key: true
      t.date :date, null: false
      t.timestamps
    end

    add_index :referee_availabilities, %i[referee_id date], unique: true
  end

  def down
    drop_table :referee_availabilities, if_exists: true

    create_table :referee_blocked_dates do |t|
      t.references :referee, null: false, foreign_key: true
      t.date :date, null: false
      t.timestamps
    end

    add_index :referee_blocked_dates, %i[referee_id date], unique: true
  end
end
