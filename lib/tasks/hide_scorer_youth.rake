# lib/tasks/hide_scorer_youth.rake
#
# Setzt enable_scorer = false bei allen Ligen der Altersklasse U13 und juenger
# (ueber ALLE Saisons). Hintergrund: FD empfiehlt, die Scorerliste in der
# Altersklasse U13 und juenger nicht aktiv anzuzeigen.
#
# WICHTIG zur Altersklasse: Das Feld leagues.age_group ist als Quelle
# UNBRAUCHBAR — die Migration 20260523120000_add_age_group_to_leagues hat es bei
# allen damals existierenden Ligen pauschal auf "Herren"/"Damen" gesetzt (nach
# female-Flag), nicht auf die echte Altersklasse. Bei enable_scorer=true tragen
# 0 Ligen ein "U..."-age_group. Die U-Klasse steht zuverlaessig nur im
# Liganamen (z. B. "Regionalliga Ost U13 Junioren"). Daher wird die U-Zahl aus
# Name UND age_group gelesen (age_group als Fallback, falls kuenftig korrekt)
# und auf <= MAX_AGE gefiltert. "Ue30" u. a. beginnen nicht mit "U<Zahl>".
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
  desc 'Setzt enable_scorer=false bei U13-und-juenger-Ligen (alle Saisons, per Liganame). DRY_RUN=false zum Ausfuehren.'
  task hide_scorer_for_youth: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    max_age = (ENV['MAX_AGE'] || '13').to_i
    puts "=== Scorerliste bei U#{max_age}-und-juenger ausblenden #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    seasons = Setting.current['seasons'] || {}
    visible_count = League.where(enable_scorer: true).count

    affected = League.where(enable_scorer: true).select { |league| youth_u_leq?(league, max_age) }

    affected.sort_by { |l| [l.season_id.to_i, l.id] }.each do |league|
      season = seasons.dig(league.season_id.to_s, 'name') || "Saison #{league.season_id}"
      suffix = dry_run ? ' [DRY RUN]' : ''
      puts "--- ##{league.id} [#{season}] #{league.name}#{suffix}"
      league.update_column(:enable_scorer, false) unless dry_run
    end

    puts "\nErgebnis: #{affected.size} Ligen betroffen (von #{visible_count} mit sichtbarer Scorerliste)."
    puts '[DRY RUN] Zum Ausfuehren: rails leagues:hide_scorer_for_youth DRY_RUN=false' if dry_run
  end

  # Liga gilt als U<=max, wenn Name oder age_group eine U-Zahl (1-2 Stellen, nicht
  # von weiterer Ziffer gefolgt) enthaelt, die <= max ist. "Ue30" faellt raus.
  def youth_u_leq?(league, max)
    text = "#{league.name} #{league.age_group}"
    ages = text.scan(/\bU(\d{1,2})(?!\d)/i).flatten.map(&:to_i)
    ages.any? { |age| age.positive? && age <= max }
  end
end
