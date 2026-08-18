# lib/tasks/reopen_memberships_after_deactivation.rake
#
# Oeffnet die Vereinszugehoerigkeiten, die eine Deaktivierung vor api#472
# geschlossen hat.
#
# Genau die haben den Schaden angerichtet: Ohne gueltigen Heimatverein laesst sich
# ein Profil weder per Transferantrag noch per Direktzuweisung in einen neuen Verein
# holen, und zusammen mit dem Suchfilter auf `Player.active` war es fuer niemanden
# mehr zu finden.
#
# Was der Lauf ausdruecklich NICHT anfasst:
#
#   - die Kennzeichnung (`deactivated_at`). Dass der Verein das Profil aus seiner
#     aktiven Liste genommen hat, ist seine Entscheidung.
#   - die Lizenzen. Was damals ungueltig gesetzt wurde, bleibt ungueltig.
#
# Zusammengefuehrte Dubletten (`merged_into_id`) bleiben unberuehrt: Bei ihnen ist
# die geschlossene Zugehoerigkeit richtig, ihre Eintraege liegen am Master
# (siehe `Player#merge_into!`).
#
# Dry-Run (Standard):
#   bundle exec rails players:reopen_memberships_after_deactivation
#
# Ausfuehren:
#   bundle exec rails players:reopen_memberships_after_deactivation DRY_RUN=false
#
# Auf einzelne Gruende beschraenken (kommagetrennt, exakte Schreibweise):
#   REASONS=Vereinsaustritt,Karriereende

namespace :players do
  desc 'Von alten Deaktivierungen geschlossene Vereinszugehoerigkeiten wieder oeffnen. DRY_RUN=false zum Ausfuehren.'
  task reopen_memberships_after_deactivation: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    reasons = ENV['REASONS'].to_s.split(',').map(&:strip).reject(&:blank?)

    scope = Player.where.not(deactivated_at: nil).where(merged_into_id: nil)
    scope = scope.where(deactivation_reason: reasons) if reasons.any?

    puts "=== Geschlossene Zugehoerigkeiten wieder oeffnen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Gruende: #{reasons.any? ? reasons.join(', ') : 'alle'}"
    puts "#{scope.count} deaktivierte Profile im Blick.\n\n"

    touched = 0
    unchanged = 0
    errors = 0

    scope.order(:id).find_each do |player|
      # Vorher zaehlen: reopen_memberships_closed_by_deactivation! mutiert das
      # Objekt, danach ist der Unterschied nicht mehr ablesbar. Gezaehlt wird ueber
      # dieselbe Methode, die der Lauf danach abarbeitet – sonst verspraeche der
      # Dry-Run mehr, als die Ausfuehrung einloest.
      memberships = player.memberships_reopenable.count

      if memberships.zero?
        unchanged += 1
        next
      end

      grund = player.deactivation_reason.presence || 'ohne Grund'
      puts "##{player.id} #{player.first_name} #{player.last_name} " \
           "(#{grund}, #{player.deactivated_at.strftime('%d.%m.%Y')}): " \
           "#{memberships} Zugehoerigkeit(en)"

      unless dry_run
        begin
          player.reopen_memberships_closed_by_deactivation!
        rescue StandardError => e
          errors += 1
          puts "  FEHLER: #{e.class}: #{e.message}"
          next
        end
      end

      touched += 1
    end

    puts
    puts "#{touched} Profil(e) #{dry_run ? 'zu oeffnen' : 'geoeffnet'}, #{unchanged} ohne geschlossene Zugehoerigkeit, #{errors} Fehler."
    puts 'Dry-Run — nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run
  end
end
