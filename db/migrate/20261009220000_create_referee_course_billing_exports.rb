# Rechnungsexporte der Schiedsrichterkurse je Landesverband. Jede abgerechnete
# Anmeldung verweist auf ihren Export (billing_export_id), damit nichts doppelt
# berechnet wird. Die erzeugte Datei haengt als Anhang am Export.
class CreateRefereeCourseBillingExports < ActiveRecord::Migration[7.2]
  def change
    create_table :referee_course_billing_exports do |t|
      t.references :state_association, foreign_key: true, comment: 'NULL: bundesweite Kurse (FD)'
      t.references :created_by_user, foreign_key: { to_table: :users }
      t.date :from_date
      t.date :to_date
      t.integer :row_count, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      t.timestamps
    end
    add_foreign_key :referee_course_registrations, :referee_course_billing_exports, column: :billing_export_id
    add_index :referee_course_registrations, :billing_export_id
  end
end
