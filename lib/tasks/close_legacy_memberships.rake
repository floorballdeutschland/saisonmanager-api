# lib/tasks/close_legacy_memberships.rake
#
# Schließt offene Legacy-Vereinsmitgliedschaften (created_at nil & valid_until nil)
# zum Startdatum (created_at) des frühesten datierten Folgevereins.
#
# ACHTUNG Semantik (seit Vorfall 2026-07-13): Heimatmitgliedschaften (home_club:
# true) werden NUR durch einen datierten Heimat-Folgeeintrag (= echter Vereins-
# wechsel) geschlossen — eine bloße Freigabe beendet die Heimatmitgliedschaft
# nicht. Details in LegacyImport::MembershipCloser.
#
# Unterschied zu players:fix_club_valid_until: dieser Task setzt das EXAKTE
# Startdatum des Folgevereins als Ende (kein Saisonende-Heuristik, keine Lücke).
# Ohne datierten Folgeeintrag bleibt die Mitgliedschaft offen.
#
# Dry-Run (Standard):
#   bundle exec rails players:close_legacy_memberships
# Ausführen:
#   bundle exec rails players:close_legacy_memberships DRY_RUN=false

namespace :players do
  desc 'Schließt offene Legacy-Mitgliedschaften zum Startdatum des Folgevereins. DRY_RUN=false zum Ausführen.'
  task close_legacy_memberships: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Legacy-Mitgliedschaften schließen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    # Nur Spieler mit mindestens einem offenen Legacy-Eintrag laden.
    scope = Player.where(
      "EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(clubs,'[]'::jsonb)) e " \
      "WHERE e->>'created_at' IS NULL AND e->>'valid_until' IS NULL)"
    )

    total_players = 0
    total_entries = 0

    scope.find_each do |player|
      new_clubs, changed = LegacyImport::MembershipCloser.close(player.clubs)
      next unless changed

      # Geschlossen wird pro Eintrag (Heimat nur durch Heimat-Folgeeintrag) —
      # daher aus dem Diff zählen statt pauschal alle offenen Legacy-Einträge.
      closed_entries = new_clubs.each_with_index.reject { |c, i| c == player.clubs[i] }.map(&:first)
      total_players += 1
      total_entries += closed_entries.size

      suffix = dry_run ? ' [DRY RUN]' : ''
      details = closed_entries.map { |c| "club #{c['club_id']} → #{c['valid_until']}" }.join(', ')
      puts "--- ##{player.id} #{player.last_name}, #{player.first_name}: #{details}#{suffix}"

      unless dry_run
        player.clubs = new_clubs
        player.save!(validate: false)
      end
    end

    puts "\nErgebnis: #{total_players} Spieler, #{total_entries} geschlossene Mitgliedschaften"
    puts '[DRY RUN] Zum Ausführen: rails players:close_legacy_memberships DRY_RUN=false' if dry_run
  end
end
