# lib/tasks/renormalize_league_class_ids.rake
#
# Normalisiert nachträglich un-normalisierte leagues.league_class_id-Werte auf
# die kanonischen Codes (League::CODES). Die Normalisierungs-Migration #297 hat
# den Bestand einmalig bereinigt; Zeilen, die danach ohne Validierung
# geschrieben wurden (Legacy-Import via update_columns/Raw-SQL), können aber
# wieder Legacy-Werte tragen. Solche Ligen lassen sich u. a. nicht kopieren
# (#114: "League class is not included in the list").
#
# Dry-Run (Standard):
#   bundle exec rails leagues:renormalize_class_ids
# Ausführen:
#   bundle exec rails leagues:renormalize_class_ids DRY_RUN=false

namespace :leagues do
  desc 'Normalisiert un-normalisierte league_class_id-Werte (#114). DRY_RUN=false zum Ausführen.'
  task renormalize_class_ids: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== league_class_id normalisieren #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    scope = League.unscoped.where.not(league_class_id: [nil, ''] + League::CODES)
    changed = 0

    scope.find_each do |league|
      new_code = League.normalize_class_id(league.league_class_id, league.name)
      next if new_code == league.league_class_id.to_s

      changed += 1
      suffix = dry_run ? ' [DRY RUN]' : ''
      puts "--- Liga ##{league.id} (S#{league.season_id}) #{league.name}: " \
           "'#{league.league_class_id}' → '#{new_code}'#{suffix}"

      league.update_columns(league_class_id: new_code) unless dry_run
    end

    puts "\nErgebnis: #{changed} Liga(en) normalisiert"
    puts '[DRY RUN] Zum Ausführen: rails leagues:renormalize_class_ids DRY_RUN=false' if dry_run
  end
end
