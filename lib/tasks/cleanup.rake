# lib/tasks/cleanup.rake

namespace :cleanup do
  desc 'Löscht inaktive VM/TM-Benutzerkonten, die sich seit mehr als 3 Jahren nicht eingeloggt haben (DRY_RUN=1 zum Testen)'
  task inactive_users: :environment do
    threshold = 3.years.ago
    dry_run = ENV['DRY_RUN'].present?

    # Nur VM (user_group_id=4) und TM (user_group_id=5) betroffen;
    # Konten mit Admin (1), SBK (2), RSK (3) oder Schiedsrichter (6) werden nicht gelöscht.
    users_to_delete = User.where(
      "NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(permissions) AS perm
        WHERE (perm->>'user_group_id')::int IN (1, 2, 3, 6)
      )"
    ).where(
      "EXISTS (
        SELECT 1 FROM jsonb_array_elements(permissions) AS perm
        WHERE (perm->>'user_group_id')::int IN (4, 5)
      )"
    ).where(
      'last_login_at < :threshold OR (last_login_at IS NULL AND created_at < :threshold)',
      threshold:
    )

    count = users_to_delete.count
    message = if dry_run
                "[DRY RUN] #{count} inaktive VM/TM-Benutzerkonten würden gelöscht."
              else
                User.transaction { users_to_delete.destroy_all }
                "#{count} inaktive VM/TM-Benutzerkonten gelöscht."
              end
    puts message
    Rails.logger.info("[cleanup:inactive_users] #{message}")
  end

  desc 'Löscht abgeschlossene Transferanträge, die seit mehr als 3 Jahren abgeschlossen sind (DRY_RUN=1 zum Testen)'
  task old_transfer_requests: :environment do
    threshold = 3.years.ago
    dry_run = ENV['DRY_RUN'].present?

    # Pro Status den jeweiligen Abschluss-Zeitstempel prüfen, statt sich auf updated_at zu verlassen,
    # da updated_at durch spätere Änderungen (z. B. Rechtschreibkorrektur einer Begründung) gesetzt werden kann.
    # Fallback auf created_at, falls der spezifische Zeitstempel (z. B. bei Altdaten) fehlt.
    requests_to_delete = TransferRequest
                         .where(status: 'approved')
                         .where('COALESCE(lv_approved_at, created_at) < :t', t: threshold)
                         .or(
                           TransferRequest
                             .where(status: %w[rejected_by_club rejected_by_lv])
                             .where('COALESCE(rejected_at, created_at) < :t', t: threshold)
                         )
                         .or(
                           TransferRequest
                             .where(status: 'revoked')
                             .where('COALESCE(revoked_at, created_at) < :t', t: threshold)
                         )
                         .or(
                           TransferRequest
                             .where(status: 'withdrawn')
                             .where('updated_at < :t', t: threshold)
                         )

    count = requests_to_delete.count
    message = if dry_run
                "[DRY RUN] #{count} abgeschlossene Transferanträge würden gelöscht."
              else
                TransferRequest.transaction { requests_to_delete.destroy_all }
                "#{count} abgeschlossene Transferanträge gelöscht."
              end
    puts message
    Rails.logger.info("[cleanup:old_transfer_requests] #{message}")
  end

  desc 'Führt alle Bereinigungsaufgaben aus (inaktive Benutzer + alte Transferanträge)'
  task all: %i[inactive_users old_transfer_requests]
end
