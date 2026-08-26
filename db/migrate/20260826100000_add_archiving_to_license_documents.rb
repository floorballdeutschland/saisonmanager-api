# Ein Lizenzdokument verschwand bisher spurlos: Ein neuer Upload derselben
# Dokumentart löschte alle vorhandenen samt Datei
# (Admin::LicenseDocumentsController#create), und `destroy` gab dem Verein
# dieselbe Möglichkeit an der Hand. Damit ließ sich nach der Erteilung einer
# Lizenz austauschen oder entfernen, worauf die Genehmigung beruhte, ohne dass
# irgendwo eine Fassung zurückblieb – `created_at` und `uploaded_by_id` galten
# stets nur für die jüngste.
#
# Statt den Upload nach der Erteilung zu sperren (das ginge nicht: Dokumente
# hängen am Spieler, nicht an der Lizenz, und per_season-Arten müssen jede
# Saison neu vorliegen), bleibt die abgelöste Fassung als archivierte Zeile
# stehen. `archived_reason` unterscheidet die beiden Wege, `archived_by_id`
# hält fest, wer sie ausgelöst hat – mit Fremdschlüssel wie uploaded_by_id
# nebenan. Ein solcher Fremdschlüssel blockiert das Löschen eines Kontos
# (vgl. den Einwand in 20260824120000_add_withdrawn_by_to_transfer_requests.rb);
# `staging_prune_limited_users` liest die betroffenen Spalten deshalb nicht mehr
# aus einer Liste, sondern aus dem Schema.
#
# Der Eindeutigkeits-Index gilt nur noch für die aktive Fassung, sonst ließe
# sich dieselbe Dokumentart kein zweites Mal hochladen, sobald eine archivierte
# Zeile existiert. Er greift ohnehin nur bei gesetzter `license_id` — für
# spielerbezogene Uploads schreibt der Controller NULL, und NULL-Werte sind in
# einem Postgres-Unique-Index verschieden. Durchgesetzt wird die Eindeutigkeit
# dort von der Validierung im Modell.
#
# Der zusätzliche Index auf (player_id, archived_at) bedient die Standardabfrage
# der Ablage, die seit dieser Änderung nach beidem filtert
# (Admin::LicenseDocumentsController#index).
#
# Getrennte up/down statt `change`: `remove_index ... name:` ohne Spaltenangabe
# ist nicht zurückrollbar (IrreversibleMigration), gleiche Bauart wie in
# 20260602100000_widen_transfer_request_active_index.rb.
class AddArchivingToLicenseDocuments < ActiveRecord::Migration[7.2]
  UNIQUE_COLUMNS = %i[player_id license_id document_type].freeze

  def up
    add_column :license_documents, :archived_at, :datetime
    add_column :license_documents, :archived_reason, :string
    add_reference :license_documents, :archived_by, foreign_key: { to_table: :users }

    remove_index :license_documents, column: UNIQUE_COLUMNS, name: 'idx_license_documents_unique'
    add_index :license_documents, UNIQUE_COLUMNS,
              unique: true, where: 'archived_at IS NULL', name: 'idx_license_documents_unique'
    add_index :license_documents, %i[player_id archived_at],
              name: 'index_license_documents_on_player_id_and_archived_at'
  end

  def down
    remove_index :license_documents, name: 'index_license_documents_on_player_id_and_archived_at'
    remove_index :license_documents, name: 'idx_license_documents_unique'

    # Bestandszeilen erst entschaerfen: Ohne den partiellen Index koennen
    # mehrere Fassungen derselben Art nebeneinander stehen, der volle Index
    # liesse sich dann nicht mehr anlegen.
    execute(<<~SQL.squish)
      DELETE FROM license_documents
      WHERE archived_at IS NOT NULL
    SQL

    add_index :license_documents, UNIQUE_COLUMNS, unique: true, name: 'idx_license_documents_unique'

    remove_reference :license_documents, :archived_by, foreign_key: { to_table: :users }
    remove_column :license_documents, :archived_reason
    remove_column :license_documents, :archived_at
  end
end
