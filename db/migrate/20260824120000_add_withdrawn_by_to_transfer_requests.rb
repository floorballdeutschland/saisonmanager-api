# Wer einen laufenden Transfer zurückzieht (VM) oder annulliert (SBK/Admin),
# blieb bisher als Einziger im Verfahren unbekannt: Anlegen, Vereinsfreigabe,
# LV-Genehmigung, Ablehnung und Widerruf hielten ihr Konto fest, der Abbruch
# nicht. Damit war gerade der Vorgang ohne Spur, zu dem am ehesten Rückfragen
# kommen.
#
# Bewusst ohne Fremdschlüssel auf users – genauso wie created_by,
# approved_by_lv_user_id und die übrigen Konto-Spalten dieser Tabelle. Ein
# archiviertes oder gelöschtes Konto darf den Antrag nicht mitreißen.
class AddWithdrawnByToTransferRequests < ActiveRecord::Migration[7.2]
  def change
    add_column :transfer_requests, :withdrawn_by, :integer
    add_column :transfer_requests, :withdrawn_at, :datetime
  end
end
