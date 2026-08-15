# lib/tasks/fix_legacy_seasons.rake
#
# Nachbereinigung der Altdaten-Importe der Saisons 2010/11-2013/14
# (season_id 2..5).
#
# Zwei Befunde, beide sind Datenluecken des Importlaufs, keine kaputten
# Spieldaten:
#
# 1) TABELLENPUNKTE
#    League#won_points / #draw_points / #won_overtime_points lesen bei
#    legacy_league == true ausschliesslich aus `league_system_id`
#    (1 => 3/1/2/1, sonst => 2/0/0/0). Der Import von 2010-2014 hat das alte
#    `id_spielsystem` aber nach `table_modus` geschrieben
#    (LegacyImport::Vocab::SPIELSYSTEM_TABLE_MODUS, Transformer#league_attrs)
#    und `league_system_id` leer gelassen. Ergebnis: alle Ligen dieser vier
#    Saisons rechnen mit 2 Punkten pro Sieg und 0 Punkten fuer Unentschieden,
#    Sieg n.V. und Niederlage n.V. Der frueher gelaufene Import der Saisons ab
#    6 hat `id_spielsystem` dagegen direkt nach `league_system_id` geschrieben
#    (dort stehen genau die Alt-Werte 1 und 4).
#    Der Backfill schreibt denselben Wert nach, den der alte Importweg
#    geschrieben haette -- die Information steckt bereits in `table_modus`.
#
# 2) SCORERLISTE
#    Die Scorerdaten sind vollstaendig da (Ereignisse mit Trikotnummer, ueber
#    die Aufstellung auf Spieler aufgeloest). Sichtbar sind sie nur nicht:
#    `leagues.enable_scorer` hat den Spalten-Default false, und der Import
#    setzt das Feld nicht. In den Saisons ab 6 steht es auf true.
#
# Beide Tasks fassen ausschliesslich Ligen mit legacy_league = true in den
# angegebenen Saisons an und sind idempotent. Kein manuelles Cache-Leeren
# noetig: leagues/:id/table und leagues/:id/scorer laufen nach 5 Minuten ab.
#
# ACHTUNG bei allen Aggregaten: League hat einen ordnenden default_scope,
# gruppierte Zaehlungen brauchen deshalb .reorder(nil).
#
# Bestandsaufnahme (nur lesend):
#   bundle exec rails legacy:report_old_seasons
#
# Dry-Run (Standard):
#   bundle exec rails legacy:backfill_league_system_id
#   bundle exec rails legacy:enable_scorer_old_seasons
# Ausfuehren:
#   bundle exec rails legacy:backfill_league_system_id DRY_RUN=false
#   bundle exec rails legacy:enable_scorer_old_seasons DRY_RUN=false
#
# Saisons ueberschreibbar (Standard 2,3,4,5):
#   bundle exec rails legacy:backfill_league_system_id SEASONS=2,3
#
# Danach unbedingt die Jugend-Regel erneut anwenden, damit U13 und juenger
# keine Scorerliste zeigen:
#   bundle exec rails leagues:hide_scorer_for_youth DRY_RUN=false

namespace :legacy do
  # table_modus (aus dem Alt-Feld id_spielsystem) -> league_system_id, so wie
  # der aeltere Importweg der Saisons ab 6 es abgelegt hat.
  def legacy_spielsystem(table_modus)
    { 'three_point' => '1', # 3-Punkte-System: 3 / 1 / 2 / 1
      'two_point' => '2',   # 2-Punkte-System
      'other' => '4' }[table_modus] # Anderes
  end

  def legacy_count_line(key, count)
    format('  %<key>-14s %<count>4d', key: key.inspect, count:)
  end

  # Ohne Sortierung, damit gruppierte Aggregate nicht am default_scope
  # scheitern (PG::GroupingError, siehe Kopfkommentar).
  def legacy_scope(seasons)
    League.reorder(nil).where(legacy_league: true, season_id: seasons)
  end

  def legacy_seasons
    (ENV['SEASONS'] || '2,3,4,5').split(',').map(&:strip).reject(&:empty?)
  end

  def legacy_season_name(season_id)
    (Setting.current.seasons || {}).dig(season_id.to_s, 'name') || "Saison #{season_id}"
  end

  def legacy_point_scheme(league)
    "Sieg #{league.won_points} / Unent. #{league.draw_points} / " \
      "Sieg n.V. #{league.won_overtime_points} / Nied. n.V. #{league.lost_overtime_points}"
  end

  def legacy_league_label(league)
    "##{league.id} [#{legacy_season_name(league.season_id)}] #{league.name}"
  end

  desc 'Bestandsaufnahme der Alt-Saisons (nur lesend): Punktesystem, league_system_id, Scorerliste.'
  task report_old_seasons: :environment do
    seasons = legacy_seasons
    scope = legacy_scope(seasons)
    puts "=== Alt-Saisons #{seasons.map { |s| legacy_season_name(s) }.join(', ')} ==="
    puts "Ligen mit legacy_league = true: #{scope.count} " \
         "(Ligen gesamt: #{League.reorder(nil).where(season_id: seasons).count})"

    { 'table_modus (Punktesystem aus dem Altsystem)' => :table_modus,
      'league_system_id (daraus rechnet League#won_points)' => :league_system_id,
      'enable_scorer' => :enable_scorer }.each do |title, column|
      puts "\n--- #{title} ---"
      scope.group(column).count.sort_by { |_k, v| -v }.each { |k, v| puts legacy_count_line(k, v) }
    end

    puts "\n--- Vergleich: Saisons 6 und 7 (frueherer Alt-Import, seit Jahren live) ---"
    older = League.reorder(nil).where(legacy_league: true, season_id: %w[6 7])
    puts "  league_system_id: #{older.group(:league_system_id).count}"
    puts "  table_modus:      #{older.group(:table_modus).count}"
    puts "  enable_scorer:    #{older.group(:enable_scorer).count}"

    puts "\n--- Betroffene Spiele ---"
    games = Game.joins(game_day: :league).where(ended: true, leagues: { legacy_league: true, season_id: seasons })
    puts "  beendete Spiele:     #{games.count}"
    puts "  davon Verlaengerung: #{games.where(overtime: true).count}"

    puts "\n--- Stichprobe: 5 Ligen mit Verlaengerungsspielen ---"
    ot_league_ids = Game.joins(:game_day).where(overtime: true).distinct.pluck('game_days.league_id')
    scope.where(id: ot_league_ids).limit(5).each do |league|
      puts "  #{legacy_league_label(league)}"
      puts "     table_modus=#{league.table_modus.inspect} league_system_id=#{league.league_system_id.inspect}"
      puts "     ist:   #{legacy_point_scheme(league)}"
      league.league_system_id = legacy_spielsystem(league.table_modus)
      puts "     waere: #{legacy_point_scheme(league)}"
    end
  end

  desc 'Schreibt league_system_id bei Alt-Ligen aus table_modus nach. DRY_RUN=false zum Ausfuehren.'
  task backfill_league_system_id: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    seasons = legacy_seasons
    puts "=== league_system_id nachtragen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Saisons: #{seasons.map { |s| legacy_season_name(s) }.join(', ')}"

    changed = 0
    already_set = 0
    unmapped = []

    legacy_scope(seasons).order(:season_id, :id).each do |league|
      if league.league_system_id.present?
        already_set += 1
        next
      end

      target = legacy_spielsystem(league.table_modus)
      if target.nil?
        unmapped << league
        next
      end

      before = legacy_point_scheme(league)
      league.league_system_id = target

      puts "--- #{legacy_league_label(league)}"
      puts "     table_modus=#{league.table_modus} -> league_system_id=#{target}"
      puts "     #{before}  =>  #{legacy_point_scheme(league)}"
      League.where(id: league.id).update_all(league_system_id: target) unless dry_run
      changed += 1
    end

    puts "\nErgebnis: #{changed} Ligen #{dry_run ? 'wuerden geaendert' : 'geaendert'}."
    puts "Uebersprungen, weil league_system_id schon gesetzt: #{already_set}"
    if unmapped.any?
      puts "Uebersprungen, weil table_modus leer/unbekannt (#{unmapped.size}) -- " \
           'diese Ligen rechnen weiter mit 2/0/0/0 und brauchen eine Einzelentscheidung:'
      unmapped.first(30).each { |l| puts "  #{legacy_league_label(l)} table_modus=#{l.table_modus.inspect}" }
      puts '  ...' if unmapped.size > 30
    end
    puts "\n[DRY RUN] Zum Ausfuehren: rails legacy:backfill_league_system_id DRY_RUN=false" if dry_run
  end

  desc 'Setzt enable_scorer=true bei den Alt-Ligen der angegebenen Saisons. DRY_RUN=false zum Ausfuehren.'
  task enable_scorer_old_seasons: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    seasons = legacy_seasons
    puts "=== Scorerliste in Alt-Saisons einschalten #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Saisons: #{seasons.map { |s| legacy_season_name(s) }.join(', ')}"

    affected = legacy_scope(seasons).where(enable_scorer: false).order(:season_id, :id).to_a
    affected.each do |league|
      puts "--- #{legacy_league_label(league)}#{dry_run ? ' [DRY RUN]' : ''}"
      league.update_column(:enable_scorer, true) unless dry_run
    end

    puts "\nErgebnis: #{affected.size} Ligen #{dry_run ? 'wuerden eingeschaltet' : 'eingeschaltet'}."
    puts 'Danach die Jugend-Regel erneut anwenden:'
    puts '  bundle exec rails leagues:hide_scorer_for_youth DRY_RUN=false'
    puts "\n[DRY RUN] Zum Ausfuehren: rails legacy:enable_scorer_old_seasons DRY_RUN=false" if dry_run
  end
end
