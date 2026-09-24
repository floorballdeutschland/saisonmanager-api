# lib/tasks/execute_scheduled_transfers.rake
#
# Taeglicher Job: Vollzieht geplante Transfers (Status "scheduled"), deren
# Wunschdatum erreicht ist. Geplant wird ein Transfer auf zwei Wegen: durch die
# LV-Genehmigung eines Antrags mit Wunschdatum (approve_lv) und durch eine
# Direktzuweisung mit Wunschdatum (direct_assign).
#
# Dieselben Riegel wie der Knopf in der Maske (Admin::TransferRequestsController#execute):
# Ein zwischenzeitlich zusammengefuehrtes Profil oder ein deaktivierter
# aufnehmender Verein wird NICHT vollzogen, der Vorgang bleibt geplant und
# erscheint in jedem Lauf wieder im Log, bis ihn jemand annulliert.
#
# Der Stichtag ist der Kalendertag in Europe/Berlin, der Server laeuft auf UTC.
# 03:00 UTC ist im Winter 04:00, im Sommer 05:00 deutscher Zeit, beides am
# selben Tag.
#
# Aufruf:           rake transfers:execute_scheduled
# Fuer Cron (taeglich): 0 3 * * * docker exec saisonmanager_rails_api bundle exec rake transfers:execute_scheduled RAILS_ENV=production >> /var/log/transfers_execute_scheduled.log 2>&1
# Vorschau ohne Aenderung: DRY_RUN=1 rake transfers:execute_scheduled

namespace :transfers do
  desc 'Vollzieht geplante Transfers, deren Wunschdatum erreicht ist. Optional DRY_RUN=1.'
  task execute_scheduled: :environment do
    dry_run = ENV['DRY_RUN'].present?
    today = Time.find_zone!('Europe/Berlin').today
    prefix = dry_run ? '[DRY RUN] ' : ''

    executed = 0
    skipped = 0
    failed = 0

    # execute_transfer! verschickt die Vollzugsmails mit deliver_later. In
    # Prod laeuft der :async-Adapter, und dessen Threads sterben mit dem
    # Rake-Prozess -- die Mails gingen still verloren (vgl. deliver_now in
    # referee_feedback.rake). Fuer die Dauer des Laufs deshalb inline.
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline unless dry_run

    TransferRequest.due_for_execution(today).includes(:player, :requesting_club).find_each do |tr|
      label = "Transfer ##{tr.id} (Spieler #{tr.player_id} -> Verein #{tr.requesting_club_id}, " \
              "Wunschdatum #{tr.effective_date&.iso8601})"

      reason = if tr.player.merged_into_id.present?
                 "Spielerprofil wurde in #{tr.player.merged_into_id} zusammengefuehrt"
               elsif tr.requesting_club.deactivated_at.present?
                 'aufnehmender Verein ist deaktiviert'
               end
      if reason
        skipped += 1
        puts "#{prefix}UEBERSPRUNGEN #{label}: #{reason}"
        next
      end

      if dry_run
        executed += 1
        puts "#{prefix}wuerde vollziehen: #{label}"
        next
      end

      begin
        # Ohne Konto: execute_transfer! schreibt dann das genehmigende Konto
        # (approved_by_lv_user_id) in die Mitgliedschaft.
        tr.execute_transfer!
        executed += 1
        puts "vollzogen: #{label}"
      rescue StandardError => e
        # Ein Vorgang darf die uebrigen nicht aufhalten. Der Status danach
        # steht mit im Log: Die Mails gehen erst nach dem Commit raus, ein
        # gescheiterter Versand hinterlaesst also einen vollzogenen Transfer
        # (approved), ein gescheiterter Vollzug einen geplanten (scheduled).
        failed += 1
        puts "FEHLER #{label}: #{e.class}: #{e.message} (Status jetzt: #{tr.reload.status})"
      end
    end

    puts "#{prefix}#{executed} geplante(r) Transfer(s) vollzogen, #{skipped} uebersprungen, #{failed} fehlgeschlagen (Stichtag #{today.iso8601})."
  ensure
    ActiveJob::Base.queue_adapter = previous_adapter if previous_adapter
  end
end
