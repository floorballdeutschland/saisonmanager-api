# lib/tasks/system_health.rake
#
# Täglicher Job: misst die Belegung des Datenträgers, auf dem die Uploads liegen,
# schreibt den Wert als Tageswert mit (daily_metrics, Kennzahl
# system_disk_used_percent) und schickt eine Mail, wenn eine Schwelle NEU
# überschritten wurde (80 Prozent Warnung, 90 Prozent kritisch).
#
# Der Vergleich läuft gegen die letzte vorliegende Messung, nicht gegen einen
# eigenen Merker: Bleibt die Belegung auf demselben Stand, kommt keine zweite
# Mail; verschlechtert sie sich von warning auf critical, kommt eine weitere.
# Eine Verbesserung löst nichts aus.
#
# Aufruf:              rake system:disk_check
# Für Cron (täglich):  30 5 * * * docker exec saisonmanager_rails_api bundle exec rake system:disk_check RAILS_ENV=production
# Vorschau ohne Wirkung: DRY_RUN=1 rake system:disk_check (kein Mailversand, kein Tageswert)

namespace :system do
  desc 'Prüft den Speicherplatz, schreibt den Tageswert mit und warnt per Mail bei neu überschrittener Schwelle. Optional DRY_RUN=1.'
  task disk_check: :environment do
    dry_run = ENV['DRY_RUN'].present?

    # Ein Probelauf schreibt auch den Tageswert nicht mit: Der Wert ist der
    # Vergleichsmaßstab des nächsten echten Laufs und würde dessen Warnung
    # unterdrücken.
    result = SystemHealth::DailyCheck.run!(notify: !dry_run, record: !dry_run)

    percent = result[:used_percent].nil? ? 'unbekannt' : "#{result[:used_percent]} %"
    puts "Belegung: #{percent} (Zustand: #{result[:status]}, vorher: #{result[:previous_status]})"

    if result[:notified]
      puts "Warnmail an #{SystemHealthMailer::NOTIFY_EMAIL} verschickt."
    elsif dry_run && SystemHealth::DailyCheck.worsened?(result[:previous_status], result[:status])
      puts "[DRY RUN] Es wäre eine Warnmail an #{SystemHealthMailer::NOTIFY_EMAIL} gegangen."
    else
      puts 'Keine Warnmail (kein neu überschrittener Schwellwert).'
    end
  end
end
