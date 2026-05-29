class CreateRefereeCourseImports < ActiveRecord::Migration[7.0]
  def change
    add_column :state_associations, :referee_license_review_enabled, :boolean,
               default: false, null: false

    # Status-Werte siehe RefereeCourseImport::STATUSES (single source of truth).
    create_table :referee_course_imports do |t|
      t.references :uploaded_by_user, null: false,
                                      foreign_key: { to_table: :users },
                                      index: true
      t.string :filename
      t.string :status, default: 'in_review', null: false
      t.integer :total_rows, default: 0, null: false
      t.timestamps
    end

    create_table :referee_course_results do |t|
      t.references :referee_course_import, null: false, foreign_key: true, index: true
      t.references :referee, null: true, foreign_key: true, index: true
      t.references :state_association, null: true, foreign_key: true

      # CSV-Rohdaten (was tatsächlich in der Datei steht)
      t.integer :csv_lizenznummer
      t.string  :csv_vorname
      t.string  :csv_nachname
      t.date    :csv_geburtsdatum
      t.string  :csv_verein
      t.string  :csv_email

      # Master-Auswahl des Importeurs
      t.integer :master_lizenznummer_by_importer
      t.string  :master_vorname_by_importer
      t.string  :master_nachname_by_importer
      t.date    :master_geburtsdatum_by_importer
      t.integer :master_club_id_by_importer
      t.string  :master_email_by_importer

      # Final übernommene Werte (gleich Importer-Werte bei direkter Übernahme,
      # ggf. vom LV überschrieben bei Korrektur-Workflow).
      t.integer :master_lizenznummer_final
      t.string  :master_vorname_final
      t.string  :master_nachname_final
      t.date    :master_geburtsdatum_final
      t.integer :master_club_id_final
      t.string  :master_email_final

      # Lizenz (read-only für LV-Reviewer)
      t.string :lizenzstufe
      t.date   :gueltigkeit
      t.date   :kursstichtag

      # Flexible CSV-Detaildaten (Kurs 1, Kurs 2, Testversionen, Punkte, Ausbilder, ...)
      t.jsonb :course_data, default: {}, null: false

      # Pro-Zeilen-Warnings vom CSV-Parser (z.B. unparsebare Datums-/Zahlenwerte).
      # Shape: [{field:, raw:, reason:}, ...]
      t.jsonb :import_warnings, default: [], null: false

      # Matching (siehe RefereeCourseResult::MATCH_TYPES / STATUSES für die
      # zulässigen Werte — Model ist single source of truth).
      t.string  :match_type, null: false
      t.integer :match_field_count, default: 0, null: false
      t.boolean :new_referee_created, default: false, null: false

      # Workflow
      t.string :status, default: 'pending_review', null: false
      t.references :reviewed_by_user, foreign_key: { to_table: :users }
      t.datetime :reviewed_at
      t.datetime :applied_at
      t.text :rejection_reason

      t.timestamps
    end

    add_index :referee_course_results, %i[state_association_id status]
    add_index :referee_course_results, :status
  end
end
