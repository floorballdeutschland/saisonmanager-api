# lib/tasks/expire_transfers.rake
#
# Täglicher Job: Annulliert offene Transferanträge, die nicht innerhalb von
# TransferRequest::EXPIRE_AFTER_DAYS (14) Tagen abgeschlossen wurden – d.h. noch
# in einem pending_*-Status hängen. Der Antrag wird auf Status "expired" gesetzt.
# Keine Erinnerungsmail vor Fristablauf (bewusst, siehe Issue #243).
#
# Aufruf:           rake transfers:expire
# Für Cron (täglich): 0 3 * * * cd /app && bundle exec rake transfers:expire
# Vorschau ohne Änderung: DRY_RUN=1 rake transfers:expire

namespace :transfers do
  desc 'Annulliert offene Transferanträge älter als 14 Tage (Status "expired"). Optional DRY_RUN=1.'
  task expire: :environment do
    dry_run = ENV['DRY_RUN'].present?

    due = TransferRequest.expirable
    count = due.count

    unless dry_run
      due.find_each(&:expire!)
      Rails.cache.delete('transfers') unless count.zero?
    end

    msg = "#{count} offene(r) Transferantrag/-anträge automatisch annulliert (älter als #{TransferRequest::EXPIRE_AFTER_DAYS} Tage)"
    puts(dry_run ? "[DRY RUN] #{msg}." : "#{msg}.")
  end
end
