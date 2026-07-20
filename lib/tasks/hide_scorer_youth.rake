# lib/tasks/hide_scorer_youth.rake
#
# Setzt enable_scorer = false bei allen Ligen der Altersklasse U13 und juenger
# (ueber ALLE Saisons). Hintergrund: FD empfiehlt, die Scorerliste in der
# Altersklasse U13 und juenger nicht aktiv anzuzeigen.
#
# Die Altersklasse steckt im Freitext-Feld leagues.age_group (z. B. "U13",
# "U13 Junioren", "U13 Juniorinnen"). Es gibt keine numerische Sortierung, daher
# wird die Zahl hinter dem fuehrenden "U" geparst und auf <= 13 gefiltert.
# "Ue30"/"Herren"/"Damen" u. a. beginnen nicht mit "U<Zahl>" und fallen raus.
#
# Nur Ligen mit enable_scorer = true werden angefasst (die uebrigen sind bereits
# unsichtbar). Kein manuelles Cache-Invalidieren noetig: die betroffenen
# Public-Caches (leagues/:id/scorer etc.) laufen nach 5 Minuten ab.
#
# Dry-Run (Standard):
#   bundle exec rails leagues:hide_scorer_for_youth
# Ausfuehren:
#   bundle exec rails leagues:hide_scorer_for_youth DRY_RUN=false
#
# Obergrenze der Altersklasse ueberschreibbar (Standard 13):
#   bundle exec rails leagues:hide_scorer_for_youth MAX_AGE=11

namespace :leagues do
  desc 'Setzt enable_scorer=false bei U13-und-juenger-Ligen (alle Saisons). DRY_RUN=false zum Ausfuehren.'
  task hide_scorer_for_youth: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    max_age = (ENV['MAX_AGE'] || '13').to_i
    puts "=== Scorerliste bei U#{max_age}-und-juenger ausblenden #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    # Vorfilter in SQL: nur aktuell sichtbare Ligen, deren age_group mit U<Zahl>
    # beginnt. Der numerische <= MAX_AGE-Vergleich passiert danach in Ruby.
    scope = League.where(enable_scorer: true).where("age_group ~* '^U[0-9]'")

    seasons = Setting.current['seasons'] || {}
    affected = scope.select do |league|
      age = league.age_group.to_s[/\AU(\d+)/i, 1]&.to_i
      age && age <= max_age
    end

    affected.sort_by { |l| [l.season_id.to_i, l.id] }.each do |league|
      season = seasons.dig(league.season_id.to_s, 'name') || "Saison #{league.season_id}"
      suffix = dry_run ? ' [DRY RUN]' : ''
      puts "--- ##{league.id} [#{season}] #{league.age_group} — #{league.name}#{suffix}"
      league.update_column(:enable_scorer, false) unless dry_run
    end

    puts "\nErgebnis: #{affected.size} Ligen betroffen (von #{scope.size} sichtbaren U-Ligen geprueft)."
    puts '[DRY RUN] Zum Ausfuehren: rails leagues:hide_scorer_for_youth DRY_RUN=false' if dry_run
  end
end
