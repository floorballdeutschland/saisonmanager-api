# Loeschfristen der Kursanmeldungen (Entscheidung 09.10.2026):
# - Anmeldungen, aus denen nie ein Schiri wurde (kein referee_id), 12 Monate
#   nach Kursende bzw. nach der Absage des Kurses. Die Antworten der
#   Zusatzfelder stehen an der Anmeldung und gehen mit.
# - Nie bestaetigte Anmeldungen (E-Mail oder Erziehungsberechtigte) eine Woche
#   nach Ablauf ihres Links: Sie waren nie gueltig.
# Anmeldungen mit Kursergebnis bleiben stehen.
#
# Cron (Prod, UTC): woechentlich, z. B.
#   0 3 * * 1 docker exec saisonmanager_rails_api bundle exec rake referee_course_registrations:purge RAILS_ENV=production >> /var/log/referee_course_purge.log 2>&1
# Vorschau: DRY_RUN=1
namespace :referee_course_registrations do
  desc 'Kursanmeldungen nach Ablauf der Loeschfrist entfernen (DRY_RUN=1 fuer Vorschau)'
  task purge: :environment do
    dry_run = ENV['DRY_RUN'].present?
    puts "Kursanmeldungen loeschen#{' (DRY_RUN)' if dry_run} am #{Time.current.iso8601}"

    scopes = RefereeCourseRegistrationPurge.scopes
    scopes.each do |label, scope|
      count = scope.count
      puts "  #{label}: #{count}"
      next if dry_run || count.zero?

      scope.in_batches(of: 200, &:delete_all)
    end
  end
end
