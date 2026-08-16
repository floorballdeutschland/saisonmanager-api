namespace :data_health do
  desc 'Alle Data-Health-Checks ausführen (exit 1 bei Funden)'
  task check_all: :environment do
    results = {
      stale_active_licenses: stale_active_licenses_findings,
      orphan_licenses: orphan_licenses_findings,
      missing_season_id: missing_season_id_findings,
      multiple_home_clubs: multiple_home_clubs_findings,
      season_min_ids_unset: season_min_ids_unset_findings,
      duplicate_active_licenses: duplicate_active_licenses_findings,
      orphan_teams: orphan_teams_findings,
      orphan_cup_leagues: orphan_cup_leagues_findings
    }

    results.each { |check, findings| report(check.to_s, findings, summary_for(check, findings)) }

    failing = results.select { |_k, v| v.any? }.keys
    if failing.any?
      puts "\n[data_health] #{failing.size} Check(s) mit Befunden: #{failing.join(', ')}"
      exit 1
    else
      puts "\n[data_health] Alle Checks unauffällig."
    end
  end

  desc 'Lizenzen mit APPROVED/REQUESTED deren Team zu einer Vorsaison gehört'
  task stale_active_licenses: :environment do
    findings = stale_active_licenses_findings
    report('stale_active_licenses', findings, summary_for(:stale_active_licenses, findings))
    exit 1 if findings.any?
  end

  desc 'Lizenzen deren Team nicht mehr in der DB existiert (Waisen)'
  task orphan_licenses: :environment do
    findings = orphan_licenses_findings
    report('orphan_licenses', findings, summary_for(:orphan_licenses, findings))
    exit 1 if findings.any?
  end

  desc 'Lizenzen ohne season_id deren Team existiert (Kandidaten für backfill)'
  task missing_season_id: :environment do
    findings = missing_season_id_findings
    report('missing_season_id', findings, summary_for(:missing_season_id, findings))
    exit 1 if findings.any?
  end

  desc 'Player mit mehr als einem aktiven home_club=true-Eintrag'
  task multiple_home_clubs: :environment do
    findings = multiple_home_clubs_findings
    report('multiple_home_clubs', findings, summary_for(:multiple_home_clubs, findings))
    exit 1 if findings.any?
  end

  desc 'Saisons in Setting ohne min_league_id/min_team_id die aktive Ligen haben'
  task season_min_ids_unset: :environment do
    findings = season_min_ids_unset_findings
    report('season_min_ids_unset', findings, summary_for(:season_min_ids_unset, findings))
    exit 1 if findings.any?
  end

  desc 'Player mit mehr als einer APPROVED-Lizenz pro (season_id, team_id)'
  task duplicate_active_licenses: :environment do
    findings = duplicate_active_licenses_findings
    report('duplicate_active_licenses', findings, summary_for(:duplicate_active_licenses, findings))
    exit 1 if findings.any?
  end

  desc 'Mannschaften deren league_id auf eine gelöschte Liga zeigt (Waisen)'
  task orphan_teams: :environment do
    findings = orphan_teams_findings
    report('orphan_teams', findings, summary_for(:orphan_teams, findings))
    exit 1 if findings.any?
  end

  desc 'Mannschaften mit gelöschten Liga-IDs in cup_leagues'
  task orphan_cup_leagues: :environment do
    findings = orphan_cup_leagues_findings
    report('orphan_cup_leagues', findings, summary_for(:orphan_cup_leagues, findings))
    exit 1 if findings.any?
  end

  # `teams.league_id` hatte bis #293 keinen Fremdschlüssel, obwohl `game_days`
  # und `league_qualifications` ihn längst hatten (`db/schema.rb`). Eine
  # Mannschaft konnte deshalb auf eine Liga zeigen, die es nicht mehr gibt, und
  # niemand merkte es. Die Mannschaftsseite antwortete darauf vor #283 mit einem
  # Serverfehler, seitdem mit einer eigenen Meldung; für Besucher ist sie in
  # beiden Fällen leer.
  #
  # Den Riegel setzt jetzt die Migration `20260816090000`. Diese Prüfung bleibt
  # als Netz für alles, was am Fremdschlüssel vorbeikommt: ein `pg_restore` ohne
  # Constraints, ein `COPY` mit abgeschalteten Triggern, oder eine spätere
  # Migration, die den Fremdschlüssel versehentlich mitnimmt.
  #
  # Woher der Altbestand stammt, ist nicht mehr rekonstruierbar. Belegbar ist nur
  # der Weg über `League...delete_all` aus der Konsole; der einzige löschende
  # Rake-Task (`cleanup:delete_empty_leagues`) überspringt Ligen mit
  # Mannschaften. Siehe #293.
  #
  # Rohes SQL statt `where.missing(:league)`: Diese Prüfung soll unabhängig von
  # jedem Scope und jeder Association-Konfiguration am Modell messen, was in der
  # Datenbank steht. Genau das ist die Frage, die auch `add_foreign_key` stellt.
  #
  # `league_id IS NULL` zählt bewusst nicht mit: Der Fremdschlüssel lässt das
  # ebenfalls zu, und eine Mannschaft ohne Liga meldet sich seit #283 mit einer
  # eigenen, verständlichen Meldung.
  def orphan_teams_findings
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).map do |row|
      SELECT t.id, t.name, t.league_id, t.club_id
      FROM teams t
      LEFT JOIN leagues l ON l.id = t.league_id
      WHERE t.league_id IS NOT NULL AND l.id IS NULL
      ORDER BY t.league_id, t.id
    SQL
      { team_id: row['id'], team_name: row['name'],
        missing_league_id: row['league_id'], club_id: row['club_id'] }
    end
  end

  # Dasselbe für die Pokalligen. `cup_leagues` ist ein Integer-Array, dort kann
  # es keinen Fremdschlüssel geben (Postgres kennt keine Fremdschlüssel auf
  # Array-Elemente), und beim Löschen einer Liga wird ihre ID dort nicht
  # entfernt. Das ist also die Hälfte von #293, die dauerhaft ein Netz braucht.
  #
  # Kein bekanntes Fehlverhalten in der Anwendung: `Team#all_league_ids` gibt die
  # IDs zwar weiter, aber jeder Verbraucher löst sie über `League.where(id:)`
  # oder eine Mengenschnittmenge auf, in der eine gelöschte ID nie trifft. Die
  # Angabe ist schlicht falsch und wandert in Exporte und Verwaltungsansichten;
  # sie gehört bereinigt, bevor jemand sie als Wahrheit behandelt.
  #
  # Die fehlenden IDs kommen aus demselben SQL, das die Zeile auswählt. Eine
  # zweite Runde in Ruby (`League.exists?` je ID) wäre nicht nur ein N+1, sie
  # wäre eine zweite Definition derselben Frage: Ein NULL-Element im Array ist
  # für SQL ein Befund, für einen Ruby-Parser unsichtbar. Der Cronjob meldete
  # dann dauerhaft einen Fund, den der Bereinigungslauf nicht auflösen kann.
  def orphan_cup_leagues_findings
    ActiveRecord::Base.connection.select_all(<<~SQL.squish).map do |row|
      SELECT t.id, t.name,
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
      { team_id: row['id'], team_name: row['name'],
        missing_league_ids: parse_pg_int_array(row['missing']) }
    end
  end

  # Postgres-Integer-Array in Ruby-Integer. `select_all` dekodiert Skalare, aber
  # keine Arrays; je nach Treiberfassung kommt hier ein Ruby-Array oder das
  # Literal "{12,13}". Beides wird behandelt, damit die Prüfung nicht an der
  # Adapterversion hängt.
  def parse_pg_int_array(value)
    return [] if value.nil?
    return Array(value).compact.map(&:to_i) unless value.is_a?(String)

    value.scan(/-?\d+/).map(&:to_i)
  end

  def stale_active_licenses_findings
    current_season = Setting.current_season_id.to_i
    [].tap do |findings|
      Player.where("licenses IS NOT NULL AND licenses != '[]'").find_each do |player|
        player.licenses.each do |lic|
          team = Team.find_by(id: lic['team_id'])
          next unless team

          last_status = lic['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
          next unless License::ACTIVE_STATUSES.include?(last_status)
          next if team.league&.season_id.to_i == current_season

          findings << { player_id: player.id,
                        player_name: "#{player.first_name} #{player.last_name}",
                        team_id: team.id,
                        season_id: team.league&.season_id,
                        license_status: License::NAMES[last_status] }
        end
      end
    end
  end

  def orphan_licenses_findings
    [].tap do |findings|
      Player.where("licenses IS NOT NULL AND licenses != '[]'").find_each do |player|
        player.licenses.each do |lic|
          next if lic['team_id'].blank? || Team.exists?(lic['team_id'])

          findings << { player_id: player.id,
                        player_name: "#{player.first_name} #{player.last_name}",
                        team_id: lic['team_id'] }
        end
      end
    end
  end

  def missing_season_id_findings
    [].tap do |findings|
      Player.where("licenses IS NOT NULL AND licenses != '[]'").find_each do |player|
        player.licenses.each do |lic|
          next if lic['season_id'].present? || !Team.exists?(lic['team_id'].to_i)

          findings << { player_id: player.id,
                        player_name: "#{player.first_name} #{player.last_name}",
                        team_id: lic['team_id'] }
        end
      end
    end
  end

  def multiple_home_clubs_findings
    [].tap do |findings|
      Player.where("clubs IS NOT NULL AND clubs != '[]'").find_each do |player|
        active_home = player.clubs.count { |c| c['home_club'] == true && c['valid_until'].nil? }
        next unless active_home > 1

        findings << { player_id: player.id,
                      player_name: "#{player.first_name} #{player.last_name}",
                      home_club_count: active_home }
      end
    end
  end

  def season_min_ids_unset_findings
    [].tap do |findings|
      Setting.current.seasons.each do |season_key, season_data|
        next unless League.exists?(season_id: season_key.to_i)
        next if season_data['min_league_id'].present? && season_data['min_team_id'].present?

        findings << { season_id: season_key.to_i,
                      name: season_data['name'],
                      min_league_id: season_data['min_league_id'],
                      min_team_id: season_data['min_team_id'] }
      end
    end
  end

  def duplicate_active_licenses_findings
    [].tap do |findings|
      Player.where("licenses IS NOT NULL AND licenses != '[]'").find_each do |player|
        counts = Hash.new(0)
        player.licenses.each do |lic|
          last_status = lic['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
          next unless last_status == License::APPROVED

          counts[[lic['season_id'], lic['team_id']]] += 1
        end
        counts.each do |(season_id, team_id), count|
          next unless count > 1

          findings << { player_id: player.id,
                        player_name: "#{player.first_name} #{player.last_name}",
                        season_id: season_id, team_id: team_id, count: count }
        end
      end
    end
  end

  def summary_for(check, findings)
    {
      stale_active_licenses: "#{findings.size} Lizenz(en) mit aktivem Status in Vorsaison-Team",
      orphan_licenses: "#{findings.size} Waisenlizenz(en) deren Team nicht mehr existiert",
      missing_season_id: "#{findings.size} Lizenz(en) ohne season_id (→ licenses:backfill_season_ids)",
      multiple_home_clubs: "#{findings.size} Player mit mehr als einem aktiven home_club=true-Eintrag",
      season_min_ids_unset: "#{findings.size} Saison(en) mit aktiven Ligen aber fehlendem min_league_id/min_team_id",
      duplicate_active_licenses: "#{findings.size} Doppelt-APPROVED-Lizenz(en) pro (player, season_id, team_id)",
      orphan_teams: "#{findings.size} Mannschaft(en) deren league_id auf eine gelöschte Liga zeigt " \
                    '(→ cleanup:orphan_team_leagues)',
      orphan_cup_leagues: "#{findings.size} Mannschaft(en) mit gelöschten Liga-IDs in cup_leagues " \
                          '(→ cleanup:orphan_team_leagues)'
    }.fetch(check.to_sym, "#{findings.size} Befunde")
  end

  def report(check_name, findings, summary)
    if ENV.fetch('FORMAT', 'text') == 'json'
      puts({ check: check_name, count: findings.size, findings: findings }.to_json)
    else
      puts "[data_health:#{check_name}] #{summary}"
      findings.first(10).each { |f| puts "  #{f.inspect}" }
      puts "  ... (#{findings.size - 10} weitere)" if findings.size > 10
    end
  end
end
