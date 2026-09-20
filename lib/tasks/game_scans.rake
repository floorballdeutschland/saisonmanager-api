# Spielberichtsbogen: Aufräumen abgelaufener Scans und die Erinnerung an
# fehlende.
#
# `remind` MUSS per Cron laufen, sonst geht die Erinnerung nie raus – sie hängt
# an keinem Request mehr. Stündlich, damit sie zeitnah nach Ablauf der
# Schonfrist ankommt:
#   bundle exec rails game_scans:remind
#
# `DRY_RUN=1` zählt nur und verschickt nichts.
namespace :game_scans do
  desc 'Delete expired game scan files and records'
  task cleanup: :environment do
    expired = GameScan.where('expires_at < ?', Time.current)
    count = expired.count
    expired.each { |gs| gs.scan_file.purge if gs.scan_file.attached? }
    expired.destroy_all
    puts "Deleted #{count} expired game scan(s)."
  end

  desc 'Ausrichter an fehlende Spielberichtsbogen-Scans erinnern (1 h nach Abschluss, idempotent)'
  task remind: :environment do
    dry_run = ENV['DRY_RUN'].present?
    mails = GameDayScanReminder.notify_due(dry_run: dry_run)

    puts "Scan-Erinnerung: #{mails} Mail(s)#{dry_run ? ' faellig (DRY_RUN, nichts verschickt)' : ' versendet'}."
  end
end
