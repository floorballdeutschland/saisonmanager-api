# Schiedsrichterkurse im System. Loest den CSV-Import der Kursergebnisse ab
# (RefereeCourseImport); die Ergebnisse laufen weiter ueber
# RefereeCourseResult, das dafuer eine Verbindung zum Kurs bekommt.
class CreateRefereeCourses < ActiveRecord::Migration[7.2]
  def change
    create_table :referee_courses do |t|
      t.string :title, null: false
      t.string :course_type, null: false
      t.integer :license_level_ids, array: true, default: [], null: false,
                                    comment: 'Erlaubte Ziel-Lizenzstufen (referee_license_levels). Leer: keine Lizenz.'
      t.references :state_association, foreign_key: true,
                                       comment: 'Verantwortlicher LV. NULL: bundesweiter Kurs (FD).'
      t.integer :partner_state_association_ids, array: true, default: [], null: false,
                                                comment: 'Weitere LV, die den Kurs mitverwalten.'
      t.references :hosting_club, foreign_key: { to_table: :clubs }
      t.references :prerequisite_course, foreign_key: { to_table: :referee_courses }
      t.text :prerequisites_note
      t.string :format, null: false, default: 'in_person'
      t.jsonb :sessions, null: false, default: [],
                         comment: '[{starts_at, ends_at, format, location, online_url}]'
      t.date :starts_on
      t.date :ends_on
      t.string :online_platform
      t.string :registration_mode, null: false, default: 'open'
      t.integer :min_participants
      t.integer :max_participants
      t.datetime :registration_opens_at
      t.datetime :registration_deadline
      t.datetime :cancellation_deadline
      t.integer :min_age
      t.integer :fee_member_cents
      t.integer :fee_non_member_cents
      t.boolean :fee_only_on_license, null: false, default: false
      t.boolean :no_show_billable, null: false, default: false
      t.boolean :bill_state_association, null: false, default: false
      t.string :fee_note
      t.boolean :public, null: false, default: true
      t.string :status, null: false, default: 'draft'
      t.string :contact_email
      t.text :description
      t.references :created_by_user, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :referee_courses, :starts_on
    add_index :referee_courses, :status

    create_table :referee_course_leads do |t|
      t.references :referee_course, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.boolean :lead, null: false, default: false
      t.timestamps
    end
    add_index :referee_course_leads, %i[referee_course_id user_id], unique: true

    # Vorlage je LV. NULL = Vorlage fuer bundesweite Kurse.
    create_table :referee_course_field_templates do |t|
      t.references :state_association, foreign_key: true
      t.string :label, null: false
      t.string :field_type, null: false
      t.jsonb :options, null: false, default: []
      t.boolean :required, null: false, default: false
      t.integer :position, null: false, default: 0
      t.string :help_text
      t.boolean :visible_to_lead, null: false, default: true
      t.boolean :include_in_billing_export, null: false, default: false
      t.timestamps
    end

    create_table :referee_course_fields do |t|
      t.references :referee_course, null: false, foreign_key: true
      t.string :label, null: false
      t.string :field_type, null: false
      t.jsonb :options, null: false, default: []
      t.boolean :required, null: false, default: false
      t.integer :position, null: false, default: 0
      t.string :help_text
      t.boolean :visible_to_lead, null: false, default: true
      t.boolean :include_in_billing_export, null: false, default: false
      t.datetime :archived_at, comment: 'Ausgeblendet statt geloescht, damit vorhandene Antworten lesbar bleiben.'
      t.timestamps
    end

    create_table :referee_course_registrations do |t|
      t.references :referee_course, null: false, foreign_key: true
      t.references :referee, foreign_key: true
      t.references :user, foreign_key: true
      t.string :vorname, null: false
      t.string :nachname, null: false
      t.date :geburtsdatum, null: false
      t.string :email
      t.string :telefon
      t.references :club, foreign_key: true, comment: 'NULL: kein Verein'
      t.references :billing_club, foreign_key: { to_table: :clubs },
                                  comment: 'Kostenuebernehmender Verein, Vorgabe = club_id'
      t.text :billing_address, comment: 'Nur ohne Verein'
      t.text :remarks
      t.references :desired_license_level, foreign_key: { to_table: :referee_license_levels }
      t.references :awarded_license_level, foreign_key: { to_table: :referee_license_levels }
      t.string :stated_lizenznummer
      t.string :guardian_name
      t.string :guardian_email
      t.datetime :guardian_confirmed_at
      t.string :status, null: false, default: 'registered'
      t.datetime :cancelled_at
      t.string :result
      t.string :test_version
      t.decimal :points, precision: 6, scale: 2
      t.string :identity_match, null: false, default: 'new_person'
      t.jsonb :match_candidates, null: false, default: []
      t.jsonb :custom_answers, null: false, default: {}
      t.string :email_confirmation_token_digest
      t.string :cancel_token_digest
      t.string :consent_version
      t.datetime :consent_at
      t.string :consent_ip
      t.datetime :billed_at
      t.bigint :billing_export_id
      t.references :registered_by_user, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :referee_course_registrations, %i[referee_course_id referee_id], unique: true,
                                                                              where: 'referee_id IS NOT NULL',
                                                                              name: 'idx_course_registrations_unique_referee'
    # Mit Vorname: Zwillinge teilen Geburtsdatum und oft die Adresse der Eltern
    # (siehe die Zwillingsregel im Kursimport).
    add_index :referee_course_registrations,
              'referee_course_id, lower(email), geburtsdatum, lower(vorname)',
              unique: true, where: 'email IS NOT NULL', name: 'idx_course_registrations_unique_person'
    add_index :referee_course_registrations, :email_confirmation_token_digest, unique: true
    add_index :referee_course_registrations, :cancel_token_digest, unique: true

    # Ergebniszeilen aus einem Kurs statt aus einem CSV-Import.
    add_reference :referee_course_results, :referee_course, foreign_key: true
    add_reference :referee_course_results, :referee_course_registration, foreign_key: true
    change_column_null :referee_course_results, :referee_course_import_id, true
  end
end
