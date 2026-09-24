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
# Der Stichtag ist TransferRequest.today (Europe/Berlin), der Server laeuft auf
# UTC. 03:00 UTC ist im Winter 04:00, im Sommer 05:00 deutscher Zeit, beides
# am selben Tag.
#
# Aufruf:           rake transfers:execute_scheduled
# Fuer Cron (taeglich): 0 3 * * * docker exec saisonmanager_rails_api bundle exec rake transfers:execute_scheduled RAILS_ENV=production >> /var/log/transfers_execute_scheduled.log 2>&1
# Vorschau ohne Aenderung: DRY_RUN=1 rake transfers:execute_scheduled

namespace :transfers do
  desc 'Vollzieht geplante Transfers, deren Wunschdatum erreicht ist. Optional DRY_RUN=1.'
  task execute_scheduled: :environment do
    dry_run = ENV['DRY_RUN'].present?
    today = TransferRequest.today
    prefix = dry_run ? '[DRY RUN] ' : ''
    counts = Hash.new(0)

    # execute_transfer! verschickt die Vollzugsmails mit deliver_later. Mit dem
    # :async-Pool gingen sie beim Ende des Rake-Prozesses verloren;
    # BlockingMailDeliveryAdapter stellt sie waehrend des Laufs zu, wiederholt
    # 4xx-Abweisungen und haelt einen Fehler bei der einen Mail.
    mail_job = ActionMailer::Base.delivery_job
    mail_job = mail_job.constantize if mail_job.is_a?(String)

    mail_adapter = BlockingMailDeliveryAdapter.around(mail_job) do
      TransferRequest.due_for_execution(today).includes(:player, :requesting_club).find_each do |tr|
        label = "Transfer ##{tr.id} (Spieler #{tr.player_id} -> Verein #{tr.requesting_club_id}, " \
                "Wunschdatum #{tr.effective_date&.iso8601})"

        reason = if tr.player.merged_into_id.present?
                   "Spielerprofil wurde in #{tr.player.merged_into_id} zusammengefuehrt"
                 elsif tr.requesting_club.deactivated_at.present?
                   'aufnehmender Verein ist deaktiviert'
                 end
        if reason
          counts[:skipped] += 1
          puts "#{prefix}UEBERSPRUNGEN #{label}: #{reason}"
          next
        end

        if dry_run
          counts[:executed] += 1
          puts "#{prefix}wuerde vollziehen: #{label}"
          next
        end

        begin
          # Ohne Konto: execute_transfer! schreibt dann das genehmigende Konto
          # (approved_by_lv_user_id) in die Mitgliedschaft.
          tr.execute_transfer!
          counts[:executed] += 1
          puts "vollzogen: #{label}"
        rescue StandardError => e
          # Ein Vorgang darf die uebrigen nicht aufhalten. Der Status danach
          # steht mit im Log, damit ein Fehler nach dem Commit (approved) von
          # einem gescheiterten Vollzug (scheduled) zu unterscheiden ist.
          counts[:failed] += 1
          puts "FEHLER #{label}: #{e.class}: #{e.message} (Status jetzt: #{tr.reload.status})"
        end
      end
    end

    mail_adapter.failures.each { |e| puts "MAILFEHLER #{e.class}: #{e.message}" }

    puts "#{prefix}#{counts[:executed]} geplante(r) Transfer(s) vollzogen, #{counts[:skipped]} uebersprungen, " \
         "#{counts[:failed]} fehlgeschlagen, #{mail_adapter.failures.size} Mail(s) nicht zugestellt " \
         "(Stichtag #{today.iso8601})."
  end
end
