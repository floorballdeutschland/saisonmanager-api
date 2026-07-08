# Zentraler Katalog der Dokumentarten für Lizenz-Pflichtdokumente
# (z. B. Unterstellungserklärung, Sportärztliches Attest). Analog zu
# referee_tags: game_operation_id = nil bedeutet global (bundesweit),
# sonst verbandsspezifisch. Lizenz-Dokumente gelten künftig pro Spieler
# (saisonübergreifend), nicht mehr pro Lizenz – license_id wird optional
# und dient nur noch als Info, in welchem Antrag das Dokument hochgeladen
# wurde. season_id (Saison des Uploads) trägt die per_season-Gültigkeit.
class CreateDocumentTypes < ActiveRecord::Migration[7.1]
  class MigrationDocumentType < ActiveRecord::Base
    self.table_name = 'document_types'
  end

  KNOWN_TYPES = {
    'parental_consent' => { name: 'Zustimmung der Erziehungsberechtigten', required_below_age: 18 },
    'id_copy' => { name: 'Ausweiskopie' }
  }.freeze

  def up
    create_table :document_types do |t|
      t.string :key, null: false
      t.string :name, null: false
      t.text :description
      t.references :game_operation, foreign_key: true, index: false
      t.string :validity, null: false, default: 'once'
      t.integer :required_below_age
      t.timestamps
    end
    add_index :document_types, :key, unique: true
    add_index :document_types, %i[game_operation_id name], unique: true

    add_column :license_documents, :season_id, :bigint
    change_column_null :license_documents, :license_id, true
    add_index :license_documents, %i[player_id document_type]

    backfill_existing_keys
  end

  def down
    remove_index :license_documents, column: %i[player_id document_type]
    change_column_null :license_documents, :license_id, false
    remove_column :license_documents, :season_id
    drop_table :document_types
  end

  private

  # Bereits verwendete document_type-Strings (Uploads + Liga-Konfiguration)
  # als globale Katalogeinträge anlegen, damit Altdaten weiter aufgelöst werden.
  def backfill_existing_keys
    keys = select_values('SELECT DISTINCT document_type FROM license_documents') |
           select_values("SELECT DISTINCT unnest(required_documents) FROM leagues WHERE required_documents <> '{}'")

    keys.compact.map(&:strip).reject(&:empty?).uniq.each do |key|
      known = KNOWN_TYPES[key] || {}
      MigrationDocumentType.create!(
        key: key,
        name: known[:name] || key.humanize,
        required_below_age: known[:required_below_age],
        validity: 'once'
      )
    end
  end
end
