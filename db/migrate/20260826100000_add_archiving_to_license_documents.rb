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
# nebenan.
#
# Der Eindeutigkeits-Index gilt nur noch für die aktive Fassung, sonst ließe
# sich dieselbe Dokumentart kein zweites Mal hochladen, sobald eine archivierte
# Zeile existiert.
class AddArchivingToLicenseDocuments < ActiveRecord::Migration[7.2]
  def change
    add_column :license_documents, :archived_at, :datetime
    add_column :license_documents, :archived_reason, :string
    add_reference :license_documents, :archived_by, foreign_key: { to_table: :users }

    remove_index :license_documents, name: 'idx_license_documents_unique'
    add_index :license_documents, %i[player_id license_id document_type],
              unique: true, where: 'archived_at IS NULL', name: 'idx_license_documents_unique'
    add_index :license_documents, %i[player_id archived_at],
              name: 'index_license_documents_on_player_id_and_archived_at'
  end
end
