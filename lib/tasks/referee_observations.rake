# frozen_string_literal: true

# Erinnerung an die angesetzten Schiedsrichtercoaches, dass ihr Beobachtungsbogen
# bereitsteht. Ausgelöst wird mit dem ANPFIFF, damit der Bogen schon während des
# Spiels aufgeschlagen werden kann (RefereeObservationReminder).
#
# MUSS per Cron laufen, sonst geht keine einzige Erinnerung raus -- es gibt
# keinen zweiten Auslöser. STÜNDLICH, damit die Mail zeitnah zum Anpfiff kommt
# und weil eine stündliche Zeile von der Zeitumstellung nicht betroffen ist (der
# Server läuft auf UTC, die Fachlogik rechnet in Europe/Berlin; eine feste
# Uhrzeit verschöbe zweimal im Jahr den Wochentag):
#
#   0 * * * * docker exec saisonmanager_rails_api bundle exec rake referee_observations:notify_due RAILS_ENV=production >> /var/log/referee_observations.log 2>&1
namespace :referee_observations do
  desc 'Angesetzte Schiedsrichtercoaches an ihren Beobachtungsbogen erinnern (idempotent)'
  task notify_due: :environment do
    mails = 0
    # deliver_now: In einem Cron-Rake gingen async-Jobs beim Prozessende verloren.
    RefereeObservationReminder.due_assignments.find_each do |assignment|
      mails += RefereeObservationReminder.new(assignment).notify(deliver_now: true)
    end

    puts "Beobachtungs-Erinnerung: #{mails} Mails versendet."
  end
end
