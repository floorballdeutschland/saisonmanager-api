# frozen_string_literal: true

# Wöchentlicher Versand der Lizenzlisten zu den anstehenden Ansetzungen.
#
# Die Listen hingen früher an der Ansetzungsmail, mit einem Link von 72 Stunden
# Gültigkeit. Angesetzt wird aber oft Wochen im Voraus, der Link war dann längst
# abgelaufen. Umgekehrt darf die Liste nicht wochenlang offen stehen, denn sie zeigt
# Namen und Geburtsdaten aller lizenzierten Spieler beider Mannschaften.
#
# MUSS per Cron laufen, sonst bleiben die Listen aus. Ein Lauf pro Woche in der
# Nacht Donnerstag → Freitag um 0 Uhr deutscher Zeit; das Fenster umfasst die
# kommenden sieben Tage (Freitag bis einschließlich Donnerstag), sodass jedes
# Spiel genau eine Mail bekommt:
#
#   # Prod-Server steht auf Etc/UTC:
#   0 23 * * 4  docker exec saisonmanager_rails_api bundle exec rake referee_license_lists:notify RAILS_ENV=production
#
# Die Stunde muss die Zeitumstellung aushalten, sonst rutscht der Lauf auf einen
# anderen Wochentag und damit das ganze Fenster um einen Tag. 23:00 UTC am
# Donnerstag ist in der Winterzeit Freitag 0:00 und in der Sommerzeit Freitag
# 1:00, liegt also in beiden Fällen auf dem Freitag.
#
# 22:00 UTC wäre falsch: Das ist nur in der Sommerzeit Freitag 0:00, in der
# Winterzeit dagegen Donnerstag 23:00. Genau die Winterzeit ist die Saison, das
# Fenster wäre dort Donnerstag bis Mittwoch, und ein Donnerstagsspiel bekäme
# seine Mail nach dem Anpfiff.
#
# Steht der Server auf Europe/Berlin, ist es einfach `0 0 * * 5`. Das Fenster
# selbst rechnet der Notifier ohnehin immer im Kalender des Spielbetriebs
# (Europe/Berlin), unabhängig von der Zone der Anwendung (UTC).
#
# Vorschau ohne Versand:
#   docker exec -e DRY_RUN=1 saisonmanager_rails_api bundle exec rake referee_license_lists:notify RAILS_ENV=production
namespace :referee_license_lists do
  desc 'Lizenzlisten für die Ansetzungen der kommenden sieben Tage verschicken (idempotent)'
  task notify: :environment do
    dry_run = ENV['DRY_RUN'].present?
    notifier = RefereeLicenseListNotifier.new
    window = RefereeLicenseListNotifier.window

    puts "Fenster: #{window.first} bis #{window.last}#{dry_run ? ' (DRY RUN)' : ''}"

    if dry_run
      mails = 0
      assignment_ids = Set.new
      notifier.each_bundle do |recipient, entries|
        mails += 1
        assignment_ids.merge(entries.map { |entry| entry[:assignment_id] })
        puts "  #{recipient.vorname} #{recipient.nachname} <#{recipient.email}>: #{entries.size} Spiel(e)"
        entries.each do |entry|
          puts "    #{entry[:date]} #{entry[:game].start_time} " \
               "#{entry[:game].home_team&.name} vs. #{entry[:game].guest_team&.name} " \
               "(#{entry[:role]}, Link gültig bis #{entry[:expires_at]})"
        end
      end
      puts "Lizenzlisten: #{mails} Mail(s) für #{assignment_ids.size} Ansetzung(en). Nichts versendet, nichts markiert."
      next
    end

    # deliver_now: In einem Cron-Rake gingen async eingereihte Jobs beim
    # Prozessende verloren (wie in referee_feedback:notify_available).
    result = notifier.run(deliver_now: true)
    puts "Lizenzlisten: #{result[:mails]} Mail(s) für #{result[:assignments]} Ansetzung(en)."
    # Eine gescheiterte Mail bricht den Lauf nicht ab (der Fall steht im Log und
    # in Sentry), darf hier aber nicht untergehen: Die betroffenen Ansetzungen
    # bleiben unmarkiert und kommen beim nächsten Lauf wieder dran, was vor dem
    # Spieltag zu spät sein kann.
    puts "ACHTUNG: #{result[:failures]} Mail(s) konnten nicht zugestellt werden." if result[:failures].positive?
  end
end
