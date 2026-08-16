# Räumt Verweise auf gelöschte Ligen aus der Tabelle `teams`.
#
# HINTERGRUND
#
# `teams.league_id` hat keinen Fremdschlüssel. `db/schema.rb` schützt
# `game_days` und `league_qualifications` nach `leagues` und `teams` nach
# `clubs`, der Eintrag `add_foreign_key "teams", "leagues"` fehlt. Eine
# Mannschaft kann deshalb auf eine Liga zeigen, die es nicht mehr gibt.
#
# Der Weg über die Anwendung ist sauber: `LeaguesController#admin_league_delete`
# löscht die eigenen Mannschaften in derselben Transaktion und blockiert, wenn
# andere Ligen betroffen wären. Verwaiste Datensätze entstehen auf allen anderen
# Wegen: `League.where(id: ...).delete_all` aus Konsole oder Rake-Task, die
# Import- und Restore-Tasks in `lib/tasks/`. Dasselbe gilt für `cup_leagues`,
# ein Integer-Array, aus dem beim Löschen einer Liga niemand die ID entfernt.
#
# Folge: Die Mannschaftsseite endete vor #283 in einem Serverfehler, seitdem in
# einem 404. Für Besucher ist sie in beiden Fällen leer.
#
# ABLAUF (Reihenfolge aus #293)
#
#   rake data_health:orphan_teams                     # 1. Bestand messen
#   rake cleanup:orphan_team_leagues                  # 2. Vorschau (Dry-Run)
#   DRY_RUN=false rake cleanup:orphan_team_leagues    # 3. bereinigen
#
# Erst danach kann `add_foreign_key "teams", "leagues"` per Migration nachgezogen
# werden; die Migration läuft nur durch, wenn hier nichts mehr übrig ist.
#
# WAS BEREINIGEN HEISST
#
# `league_id` wird auf NULL gesetzt, die Mannschaft bleibt stehen. Gelöscht wird
# nichts: Eine Mannschaft trägt Kader, Lizenzen und Spielhistorie, und welche
# Liga gemeint war, lässt sich aus der verwaisten ID nicht mehr rekonstruieren.
# Die ID steht deshalb in der Ausgabe, zusammen mit der Zeile, die den Zustand
# wiederherstellt. Eine Mannschaft ohne Liga meldet sich seit #283 mit einer
# eigenen, verständlichen Meldung.
namespace :cleanup do
  # Rohes SQL, damit die Auswahl unabhängig von Scopes und
  # Association-Konfiguration das misst, was in der Datenbank steht. Genau diese
  # Frage stellt später auch `add_foreign_key`.
  def orphan_league_rows
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT t.id, t.name, t.league_id
      FROM teams t
      LEFT JOIN leagues l ON l.id = t.league_id
      WHERE t.league_id IS NOT NULL AND l.id IS NULL
      ORDER BY t.league_id, t.id
    SQL
  end

  def orphan_cup_rows
    rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT t.id, t.name, t.cup_leagues
      FROM teams t
      WHERE t.cup_leagues IS NOT NULL AND array_length(t.cup_leagues, 1) > 0
      ORDER BY t.id
    SQL
    existing = League.unscoped.pluck(:id).to_set
    rows.filter_map do |row|
      cup_ids = parse_int_array(row['cup_leagues'])
      missing = cup_ids.reject { |id| existing.include?(id) }
      next if missing.empty?

      row.merge('parsed' => cup_ids, 'missing' => missing)
    end
  end

  # Der Adapter liefert Integer-Arrays je nach Treiberfassung als Ruby-Array
  # oder als Postgres-Literal ("{12,13}").
  def parse_int_array(value)
    return Array(value).map(&:to_i) unless value.is_a?(String)

    value.scan(/-?\d+/).map(&:to_i)
  end

  desc 'Verweise auf gelöschte Ligen in teams.league_id und teams.cup_leagues bereinigen (Dry-Run, DRY_RUN=false schreibt)'
  task orphan_team_leagues: :environment do
    dry_run = ENV.fetch('DRY_RUN', 'true') != 'false'
    puts "=== Verwaiste Liga-Verweise in teams [#{dry_run ? 'DRY RUN' : 'LIVE'}] ==="

    league_rows = orphan_league_rows
    cup_rows = orphan_cup_rows

    puts "league_id zeigt ins Leere: #{league_rows.size} Mannschaft(en)"
    league_rows.each do |row|
      puts format('  Team %<id>-7s %<name>-40s league_id=%<league_id>s',
                  id: row['id'], name: row['name'].to_s.slice(0, 40), league_id: row['league_id'])
      puts format('     ROLLBACK: Team.where(id: %<id>s).update_all(league_id: %<league_id>s)',
                  id: row['id'], league_id: row['league_id'])
      next if dry_run

      Team.where(id: row['id']).update_all(league_id: nil)
    end

    puts "cup_leagues enthält gelöschte IDs: #{cup_rows.size} Mannschaft(en)"
    cup_rows.each do |row|
      bleibt = row['parsed'] - row['missing']
      puts format('  Team %<id>-7s %<name>-40s entfernt=%<missing>s bleibt=%<bleibt>s',
                  id: row['id'], name: row['name'].to_s.slice(0, 40),
                  missing: row['missing'].inspect, bleibt: bleibt.inspect)
      puts format('     ROLLBACK: Team.where(id: %<id>s).update_all(cup_leagues: %<parsed>s)',
                  id: row['id'], parsed: row['parsed'].inspect)
      next if dry_run

      Team.where(id: row['id']).update_all(cup_leagues: bleibt)
    end

    if league_rows.empty? && cup_rows.empty?
      puts 'Nichts zu tun.'
    elsif dry_run
      puts 'DRY RUN – nichts geschrieben. Mit DRY_RUN=false ausführen.'
    else
      puts "Geschrieben. #{league_rows.size} league_id genullt, #{cup_rows.size} cup_leagues bereinigt."
    end
  end
end
