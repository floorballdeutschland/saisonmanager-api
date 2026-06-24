# Opt-out für informelle System-Mails (nur für Teammanager relevant). Default true:
# bestehende Nutzer erhalten weiterhin Mails, bis sie aktiv abwählen.
class AddReceiveInfoMailsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :receive_info_mails, :boolean, default: true, null: false
  end
end
