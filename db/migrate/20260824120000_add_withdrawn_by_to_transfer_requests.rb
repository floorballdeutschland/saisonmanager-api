# Wer einen laufenden Transfer zurückzieht (VM), annulliert (SBK/Admin) oder
# durch eine Vereinsdeaktivierung beendet, blieb als Einziger im Verfahren
# unbekannt: Anlegen, Vereinsfreigabe, LV-Genehmigung, Ablehnung und Widerruf
# hielten ihr Konto fest, der Abbruch nicht. Damit war gerade der Vorgang ohne
# Spur, zu dem am ehesten Rückfragen kommen.
#
# Bewusst ohne Fremdschlüssel auf users, wie created_by,
# approved_by_lv_user_id und die übrigen Konto-Spalten dieser Tabelle: Ein
# Fremdschlüssel würde das Löschen eines Kontos blockieren, solange noch ein
# Antrag darauf zeigt, und Anträge sind auf Dauer angelegt. Uneinheitlich im
# Projekt -- license_documents.uploaded_by_id hat einen -- hier zählt die
# Nachbarschaft in derselben Tabelle.
class AddWithdrawnByToTransferRequests < ActiveRecord::Migration[7.2]
  def change
    add_column :transfer_requests, :withdrawn_by, :integer
    add_column :transfer_requests, :withdrawn_at, :datetime
  end
end
