# lib/tasks/reset_deactivation_side_effects.rake
#
# Nimmt die Nebenwirkungen zurueck, die `Player#deactivate!` bis api#472
# mitgeschrieben hat: die von der Deaktivierung geschlossenen
# Vereinszugehoerigkeiten und die DELETED-Eintraege, die sie in den Lizenz-Verlauf
# gehaengt hat.
#
# Die Kennzeichnung selbst (`deactivated_at`) bleibt stehen. Sie ist die Entscheidung
# des Vereins, das Profil aus seiner aktiven Liste zu nehmen, und die soll dieser
# Lauf nicht ueberschreiben — er stellt nur den Zustand her, den eine Deaktivierung
# seit api#472 hinterlaesst.
#
# Zusammengefuehrte Dubletten (`merged_into_id`) bleiben unberuehrt: Bei ihnen sind
# die geschlossenen Zugehoerigkeiten richtig, ihre Eintraege liegen am Master
# (siehe `Player#merge_into!`).
#
# Dry-Run (Standard):
#   bundle exec rails players:reset_deactivation_side_effects
#
# Ausfuehren:
#   bundle exec rails players:reset_deactivation_side_effects DRY_RUN=false
#
# Auf einzelne Gruende beschraenken (kommagetrennt, exakte Schreibweise):
#   REASONS=Vereinsaustritt,Karriereende

namespace :players do
  desc 'Geschlossene Mitgliedschaften und Lizenz-Loeschungen alter Deaktivierungen zuruecknehmen. DRY_RUN=false zum Ausfuehren.'
  task reset_deactivation_side_effects: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    reasons = ENV['REASONS'].to_s.split(',').map(&:strip).reject(&:blank?)

    scope = Player.where.not(deactivated_at: nil).where(merged_into_id: nil)
    scope = scope.where(deactivation_reason: reasons) if reasons.any?

    puts "=== Deaktivierungs-Nebenwirkungen zuruecknehmen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Gruende: #{reasons.any? ? reasons.join(', ') : 'alle'}"
    puts "#{scope.count} deaktivierte Profile im Blick.\n\n"

    touched = 0
    unchanged = 0
    errors = 0

    scope.order(:id).find_each do |player|
      # Vorher pruefen, was der Lauf aendern wuerde: reset_deactivation_side_effects!
      # mutiert das Objekt, danach ist der Unterschied nicht mehr ablesbar.
      memberships = Array(player.clubs).count { |c| c.is_a?(Hash) && player.membership_closed_by_deactivation?(c) }
      licenses = Array(player.licenses).count do |l|
        last = l['history']&.last
        last && last['license_status_id'].to_i == License::DELETED && last['created_by'] == player.deactivated_by
      end

      if memberships.zero? && licenses.zero?
        unchanged += 1
        next
      end

      label = "##{player.id} #{player.first_name} #{player.last_name} " \
              "(#{player.deactivation_reason.presence || 'ohne Grund'}, " \
              "#{player.deactivated_at.strftime('%d.%m.%Y')})"
      puts "#{label}: #{memberships} Mitgliedschaft(en), #{licenses} Lizenz-Eintrag/-Eintraege"

      unless dry_run
        begin
          player.reset_deactivation_side_effects!
        rescue StandardError => e
          errors += 1
          puts "  FEHLER: #{e.class}: #{e.message}"
          next
        end
      end

      touched += 1
    end

    puts
    puts "#{touched} Profil(e) #{dry_run ? 'zu bereinigen' : 'bereinigt'}, #{unchanged} ohne Nebenwirkungen, #{errors} Fehler."
    puts 'Dry-Run — nichts geschrieben. Mit DRY_RUN=false ausfuehren.' if dry_run
  end
end
