# lib/tasks/reapply_nation_fix.rake
#
# Remappt rohe Legacy-nation_ids auf das neue Schema – identisch zur Migration
# db/migrate/20260415140000_fix_player_nation_ids.rb. Nötig, weil der finale
# Go-Live-Dump nach .org die rohen Legacy-Werte erneut eingespielt hat
# (praktisch alle Spieler zeigen "Dänemark" statt "Deutschland").
#
# Mapping (wie Migration):
#   3 → 4 (Dänemark), 4 → 1 (Deutschland), 6 → 6 (Finnland), 99 → 99,
#   alle übrigen Legacy-IDs → 99 (Sonstige)
#
# WICHTIG – nicht idempotent: auf bereits korrigierten Daten würde 4→1 echte
# Dänemark-Einträge zerstören. Deshalb bricht der Task ab, wenn keine
# Legacy-Reste (nation_id außerhalb {1,4,6,99}) mehr existieren. FORCE=1 hebt
# die Sperre auf.
#
# Dry-Run (Standard):
#   bundle exec rails players:reapply_nation_fix
# Ausführen:
#   bundle exec rails players:reapply_nation_fix DRY_RUN=false

namespace :players do
  desc 'Remappt Legacy-nation_ids auf das neue Schema (wie Migration 20260415140000). DRY_RUN=false zum Ausführen.'
  task reapply_nation_fix: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    output_ids = %w[1 4 6 99]

    puts "=== Nation-ID Remap #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    leftover = Player.where.not(nation_id: output_ids).where.not(nation_id: [nil, '']).count
    if leftover.zero? && ENV['FORCE'] != '1'
      puts 'ABBRUCH: keine Legacy-Reste (nation_id außerhalb {1,4,6,99}) gefunden – ' \
           'Daten sehen bereits korrigiert aus. FORCE=1 zum Erzwingen.'
      next
    end

    print_distribution = lambda do |label|
      top = Player.group(:nation_id).count.sort_by { |_k, v| -v }.first(8)
      puts "  #{label}: #{top.map { |k, v| "#{k.inspect}=#{v}" }.join(', ')}"
    end
    print_distribution.call('vorher')

    unless dry_run
      ActiveRecord::Base.connection.execute(<<~SQL)
        UPDATE players
        SET nation_id = CASE nation_id::text
          WHEN '3'  THEN '4'
          WHEN '4'  THEN '1'
          WHEN '6'  THEN '6'
          WHEN '99' THEN '99'
          ELSE '99'
        END
        WHERE nation_id IS NOT NULL
          AND nation_id <> ''
      SQL
      print_distribution.call('nachher')
    end

    puts '[DRY RUN] Zum Ausführen: rails players:reapply_nation_fix DRY_RUN=false' if dry_run
  end
end
