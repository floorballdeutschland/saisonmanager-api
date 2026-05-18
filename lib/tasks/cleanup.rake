# lib/tasks/cleanup.rake

namespace :cleanup do
  desc 'Löscht inaktive VM/TM-Benutzerkonten, die sich seit mehr als 3 Jahren nicht eingeloggt haben'
  task inactive_users: :environment do
    threshold = 3.years.ago

    # Nur VM (user_group_id=4) und TM (user_group_id=5) betroffen;
    # Konten mit Admin (1), SBK (2) oder RSK (3) werden nicht gelöscht.
    users_to_delete = User.where(
      "NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(permissions) AS perm
        WHERE (perm->>'user_group_id')::int IN (1, 2, 3)
      )"
    ).where(
      "EXISTS (
        SELECT 1 FROM jsonb_array_elements(permissions) AS perm
        WHERE (perm->>'user_group_id')::int IN (4, 5)
      )"
    ).where(
      "last_login_at < :threshold OR (last_login_at IS NULL AND created_at < :threshold)",
      threshold:
    )

    count = users_to_delete.count
    users_to_delete.destroy_all
    puts "#{count} inaktive VM/TM-Benutzerkonten gelöscht."
  end

  desc 'Löscht abgeschlossene Transferanträge, die seit mehr als 3 Jahren abgeschlossen sind'
  task old_transfer_requests: :environment do
    closed_statuses = %w[approved rejected_by_club rejected_by_lv revoked withdrawn]
    threshold = 3.years.ago

    requests_to_delete = TransferRequest.where(status: closed_statuses)
                                        .where("updated_at < ?", threshold)

    count = requests_to_delete.count
    requests_to_delete.destroy_all
    puts "#{count} abgeschlossene Transferanträge gelöscht."
  end

  desc 'Führt alle Bereinigungsaufgaben aus (inaktive Benutzer + alte Transferanträge)'
  task all: %i[inactive_users old_transfer_requests]
end
