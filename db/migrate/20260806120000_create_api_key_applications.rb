class CreateApiKeyApplications < ActiveRecord::Migration[7.1]
  def change
    create_table :api_key_applications do |t|
      # Selbstauskunft aus dem Antragsformular. Kommerzielle Vorhaben werden im
      # System nicht beantragt, sondern individuell abgestimmt; die Angabe wird
      # trotzdem gespeichert, weil falsche Angaben im Antrag ein Sperrgrund sind
      # (§ 11 der Nutzungsvereinbarung).
      t.boolean :commercial, null: false, default: false

      t.string :organisation, null: false
      t.string :contact_name, null: false, comment: 'Vertreten durch'
      t.string :email, null: false
      t.text :address
      t.text :project_description, null: false
      t.text :purpose, null: false
      t.string :project_url

      t.string :status, null: false, default: 'pending'

      # Nachweis der Zustimmung: Fassung, Zeitpunkt und Absender-IP.
      t.string :terms_version, null: false
      t.datetime :accepted_terms_at, null: false
      t.string :accepted_terms_ip

      t.text :decision_note
      t.integer :decided_by, comment: 'User-ID der entscheidenden Person'
      t.datetime :decided_at

      # Der Key entsteht erst, wenn der Antragsteller ihn über den Einmal-Link
      # abholt: ApiKey speichert nur den Digest, der Klartext existiert genau
      # einmal. Bis dahin bleibt api_key_id leer.
      t.references :api_key, foreign_key: true
      t.string :reveal_token_digest
      t.datetime :reveal_token_expires_at
      t.datetime :key_revealed_at

      t.timestamps
    end

    add_index :api_key_applications, :status
    add_index :api_key_applications, :email
    add_index :api_key_applications, :reveal_token_digest, unique: true

    # Doppelklick- und Mehrfachantrags-Schutz auf DB-Ebene: pro Adresse und
    # Organisation darf nur ein Antrag offen sein. Für ein weiteres Projekt muss
    # die erste Entscheidung abgewartet werden.
    add_index :api_key_applications, %i[email organisation],
              unique: true,
              where: "status = 'pending'",
              name: 'index_api_key_applications_pending_unique'
  end
end
