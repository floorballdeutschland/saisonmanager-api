# Räumt Verweise auf gelöschte Ligen aus der Tabelle `teams`.
#
# HINTERGRUND
#
# `teams.league_id` hatte bis #293 keinen Fremdschlüssel, obwohl `game_days` und
# `league_qualifications` ihn längst hatten. Eine Mannschaft konnte deshalb auf
# eine Liga zeigen, die es nicht mehr gibt. Seit der Migration `20260816090000`
# lässt die Datenbank das nicht mehr zu; dieser Task räumt den Altbestand und
# bleibt als Werkzeug für alles, was am Fremdschlüssel vorbeikommt.
#
# Für `cup_leagues` gilt das ausdrücklich NICHT: Das ist ein Integer-Array, und
# Postgres kennt keine Fremdschlüssel auf Array-Elemente. Dort bleibt dieser Task
# dauerhaft die einzige Bereinigung.
#
# Woher der Altbestand der `league_id`-Waisen stammt, ist nicht mehr
# rekonstruierbar; belegbar ist nur `League...delete_all` aus der Konsole. Für
# die `cup_leagues`-Fälle ist die Quelle dagegen gefunden und mit #293
# geschlossen: `cleanup:delete_empty_leagues` prüfte Vorsaison, Vorrunde,
# Direktvergleich und Qualifikationen, aber nicht die Pokalliga-Verweise fremder
# Mannschaften. Eine Liga, auf die nur so verwiesen wurde, galt als leer und
# wurde gelöscht.
#
# Folge: Die Mannschaftsseite endete vor #283 in einem Serverfehler, seitdem in
# einer eigenen Meldung. Für Besucher ist sie in beiden Fällen leer.
#
# ABLAUF
#
#   rake data_health:orphan_teams                     # 1. Bestand messen
#   rake cleanup:orphan_team_leagues                  # 2. Vorschau (Dry-Run)
#   DRY_RUN=false rake cleanup:orphan_team_leagues    # 3. bereinigen
#
# Der Lauf lässt sich mit ONLY auf eine Hälfte begrenzen (`league_id`,
# `cup_leagues`, Vorgabe `all`). Das ist kein Beiwerk: Die Migration bricht
# ausschließlich an `league_id` ab, und wer sie unter Deploy-Druck entsperrt,
# soll nicht ungefragt auch die Pokalliga-Angaben umschreiben.
#
# Die Ausgabe gehört gesichert, sie ist die einzige Aufzeichnung: `update_all`
# fasst `updated_at` nicht an, nach dem Lauf steht in der Datenbank nichts mehr
# über die entfernten IDs. Also mitschreiben lassen:
#
#   DRY_RUN=false rake cleanup:orphan_team_leagues | tee /tmp/orphan-$(date +%F).log
#
# WAS BEREINIGEN HEISST
#
# `league_id` wird auf NULL gesetzt, die Mannschaft bleibt stehen. Gelöscht wird
# nichts: Eine Mannschaft trägt Kader, Lizenzen und Spielhistorie, und welche
# Liga gemeint war, lässt sich aus der verwaisten ID nicht mehr rekonstruieren.
#
# Die Mannschaft ist danach allerdings nicht mehr über die Anwendung speicherbar:
# `Team belongs_to :league` ist Pflicht (`belongs_to_required_by_default`), jedes
# `update!` scheitert an der Validierung, bis ihr eine Liga zugewiesen wurde. Die
# Bereinigung ist also der erste Schritt, nicht der letzte. Der Lauf gibt die
# betroffenen Mannschaften am Ende noch einmal aus.
namespace :cleanup do
  # Keine Konstante: In einem Rake-Block landete sie global auf Object.
  def only_modes
    %w[all league_id cup_leagues]
  end

  # Rohes SQL, damit die Auswahl unabhängig von Scopes und
  # Association-Konfiguration das misst, was in der Datenbank steht. Dieselbe
  # Frage stellt `add_foreign_key` in der Migration `20260816090000`.
  def orphan_league_rows
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).to_a
      SELECT t.id, t.name, t.league_id
      FROM teams t
      LEFT JOIN leagues l ON l.id = t.league_id
      WHERE t.league_id IS NOT NULL AND l.id IS NULL
      ORDER BY t.league_id, t.id
    SQL
  end

  # Auswahl UND fehlende IDs kommen aus demselben SQL wie in
  # `data_health:orphan_cup_leagues`. Vorher waren es zwei Implementierungen
  # derselben Frage, eine in SQL und eine in Ruby, und sie liefen auseinander:
  # `l.id = NULL` trifft nie, ein NULL-Element im Array ist für `NOT EXISTS` also
  # ein Befund, für einen Ruby-Parser dagegen unsichtbar. Der Cronjob meldete
  # dann dauerhaft einen Fund, den dieser Lauf nicht auflösen konnte.
  def orphan_cup_rows
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).map do |row|
      SELECT t.id, t.name, t.cup_leagues,
             (SELECT array_agg(cup_id) FROM unnest(t.cup_leagues) AS cup_id
              WHERE NOT EXISTS (SELECT 1 FROM leagues l WHERE l.id = cup_id)) AS missing
      FROM teams t
      WHERE t.cup_leagues IS NOT NULL
        AND array_length(t.cup_leagues, 1) > 0
        AND EXISTS (
          SELECT 1 FROM unnest(t.cup_leagues) AS cup_id
          WHERE NOT EXISTS (SELECT 1 FROM leagues l WHERE l.id = cup_id)
        )
      ORDER BY t.id
    SQL
      row.merge('parsed' => parse_pg_int_array(row['cup_leagues']),
                'missing' => parse_pg_int_array(row['missing']))
    end
  end

  desc 'Verweise auf gelöschte Ligen in teams.league_id und teams.cup_leagues bereinigen ' \
       '(Dry-Run, DRY_RUN=false schreibt, ONLY=league_id|cup_leagues|all)'
  task orphan_team_leagues: :environment do
    dry_run = ENV.fetch('DRY_RUN', 'true') != 'false'
    only = ENV.fetch('ONLY', 'all')
    abort "ONLY muss eines von #{only_modes.join(', ')} sein (war: #{only})" unless only_modes.include?(only)

    puts "=== Verwaiste Liga-Verweise in teams [#{dry_run ? 'DRY RUN' : 'LIVE'}, ONLY=#{only}] ==="

    league_rows = only == 'cup_leagues' ? [] : orphan_league_rows
    cup_rows = only == 'league_id' ? [] : orphan_cup_rows
    written = 0
    skipped = 0

    puts "league_id zeigt ins Leere: #{league_rows.size} Mannschaft(en)"
    league_rows.each do |row|
      puts format('  Team %<id>-7s %<name>-40s league_id=%<league_id>s',
                  id: row['id'], name: row['name'].to_s.slice(0, 40), league_id: row['league_id'])
      # Nur vor der Migration ausführbar: Die ID existiert in `leagues` nicht
      # mehr, der Fremdschlüssel weist das UPDATE also ab. Als Aufzeichnung ist
      # sie trotzdem das Wertvollste am ganzen Lauf, sie ist der einzige Hinweis
      # darauf, welche Liga gemeint war.
      puts format('     WAR: Team %<id>s -> league_id %<league_id>s', id: row['id'], league_id: row['league_id'])
      next if dry_run

      count_write(Team.where(id: row['id']).update_all(league_id: nil), row['id']) { |ok| ok ? written += 1 : skipped += 1 }
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

      count_write(Team.where(id: row['id']).update_all(cup_leagues: bleibt), row['id']) { |ok| ok ? written += 1 : skipped += 1 }
    end

    if league_rows.empty? && cup_rows.empty?
      puts 'Nichts zu tun.'
    elsif dry_run
      puts 'DRY RUN, nichts geschrieben. Mit DRY_RUN=false ausführen.'
    else
      puts "Geschrieben: #{written} Aktualisierung(en)#{skipped.positive? ? ", #{skipped} uebersprungen" : ''}."
      report_teams_needing_a_league(league_rows) if league_rows.any?
    end
  end

  # `update_all` liefert die Zahl betroffener Zeilen. Ohne diese Auswertung
  # meldete der Lauf, was er GEFUNDEN hat, nicht was er GESCHRIEBEN hat: Eine
  # zwischenzeitlich gelöschte Mannschaft oder ein paralleler Lauf verschwanden
  # stillschweigend hinter einer Erfolgsmeldung.
  def count_write(affected, team_id)
    if affected.zero?
      puts "     WARNUNG: Team #{team_id} nicht mehr vorhanden, nichts geschrieben"
      yield false
    else
      yield true
    end
  end

  # `Team belongs_to :league` ist Pflicht. Eine Mannschaft mit league_id = NULL
  # ist gültig in der Datenbank, aber nicht mehr über die Anwendung speicherbar.
  # Das gehört an das Ende des Laufs, nicht in eine Fußnote.
  def report_teams_needing_a_league(rows)
    puts
    puts 'NACHARBEIT: Diese Mannschaften haben jetzt keine Liga und lassen sich erst wieder'
    puts 'speichern, wenn ihnen eine zugewiesen wurde (Team belongs_to :league ist Pflicht):'
    rows.each { |row| puts format('  Team %<id>-7s %<name>s', id: row['id'], name: row['name']) }
  end
end
