# lib/tasks/backfill_legacy_home_clubs.rake
#
# Setzt vereinslosen Spielerprofilen einen OFFENEN Heimatverein, damit die Vereine
# sie im eigenen Konto sehen und per Merge-Antrag mit dem lebenden Profil
# zusammenführen können.
#
# Begründung der Regeln, Gruppenlegende und die Rolle von `valid_until` stehen in
# LegacyImport::HomeClubBackfill; die Datenbeschaffung in
# LegacyImport::HomeClubBackfillData. Hier nur Bedienung und Bericht.
#
# Dry-Run (Standard):
#   bundle exec rails players:backfill_legacy_home_clubs
# Nur die Dubletten-Fälle live schreiben:
#   bundle exec rails players:backfill_legacy_home_clubs DRY_RUN=false GROUPS=A,D
# Einzelfall prüfen (filtert INNERHALB des Scopes: eine ID mit fremdem
# Vereinseintrag liefert eine leere Ausgabe, keinen Fehler):
#   bundle exec rails players:backfill_legacy_home_clubs PLAYER_IDS=12345
# Arbeitslisten je Verein als CSV (je Lauf ein eigener Unterordner):
#   bundle exec rails players:backfill_legacy_home_clubs CSV_DIR=tmp/backfill
#
# Rücknahme (entfernt ausschließlich die eigenen Einträge):
#   bundle exec rails players:rollback_legacy_home_clubs DRY_RUN=false

require 'csv'

namespace :players do
  desc 'Setzt vereinslosen Legacy-Profilen einen offenen Heimatverein (Merge-Vorbereitung). DRY_RUN=false zum Ausführen.'
  task backfill_legacy_home_clubs: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    groups = HomeClubBackfillTask.parse_groups(ENV.fetch('GROUPS', nil))
    only_ids = HomeClubBackfillTask.parse_player_ids(ENV.fetch('PLAYER_IDS', nil))
    csv_dir = HomeClubBackfillTask.prepare_csv_dir(ENV.fetch('CSV_DIR', nil))

    puts "=== Legacy-Heimatvereine nachziehen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Schreibende Gruppen: #{groups.join(', ')}"

    data = LegacyImport::HomeClubBackfillData.new
    puts "Ignorierte Platzhalter- und deaktivierte Vereine: #{data.ignore_club_ids.size}"

    scope = only_ids.any? ? data.scope.where(id: only_ids) : data.scope
    players = scope.to_a.sort_by { |p| [p.last_name.to_s, p.first_name.to_s] }
    puts "Profile im Scope: #{players.size}"
    HomeClubBackfillTask.report_scope_warnings(data, players)
    puts ''

    by_group = Hash.new { |h, k| h[k] = [] }
    club_growth = Hash.new(0)
    failures = []
    written = 0

    begin
      players.each do |player|
        result = data.decide_for(player)
        by_group[result[:group]] << [player, result]
        next unless result[:club_id] && groups.include?(result[:group])

        begin
          club = HomeClubBackfillTask.target_club!(player, result, data.ignore_club_ids)
          entry = LegacyImport::HomeClubBackfill.build_entry(
            club_id: club.id, created_at: data.earliest_license_start(player, club.id)
          )
          new_clubs, status = LegacyImport::HomeClubBackfill.apply(player.clubs, entry)
          puts HomeClubBackfillTask.decision_line(player, result, club, status, dry_run)
          next unless status == :written

          written += 1
          club_growth[club.id] += 1
          next if dry_run

          player.clubs = new_clubs
          player.save!(validate: false)
        rescue StandardError => e
          # Ein defekter Datensatz darf einen Lauf über hunderte Profile nicht
          # abbrechen, sonst fehlen Bericht, Admin-Liste und CSV komplett.
          failures << [player, e]
          puts "  [FEHLER] ##{player.id} #{player.last_name}, #{player.first_name}: #{e.message}"
        end
      end
    ensure
      HomeClubBackfillTask.report_groups(by_group, groups)
      HomeClubBackfillTask.report_admin_list(by_group['D'])
      HomeClubBackfillTask.report_growth(club_growth)
      HomeClubBackfillTask.write_csv(csv_dir, by_group, groups) if csv_dir
      HomeClubBackfillTask.report_failures(failures)
      puts "\nErgebnis: #{written} Profile mit neuem Heimatverein in #{club_growth.size} Vereinen"
      puts '[DRY RUN] Zum Ausführen: DRY_RUN=false' if dry_run
    end

    abort "\nAbbruch: #{failures.size} Profil(e) mit Fehler, siehe oben." if failures.any?
  end

  desc 'Entfernt die vom Backfill gesetzten Heimatvereine wieder. DRY_RUN=false zum Ausführen.'
  task rollback_legacy_home_clubs: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Legacy-Heimatvereine zurücknehmen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    # Ohne Filter auf deactivated_at/merged_into_id: der Marker bleibt am
    # deaktivierten Secondary stehen (`deactivate!` stempelt nur valid_until) und
    # kann zusätzlich per `_merge_clubs` auf den Master gewandert sein.
    scope = Player.where(
      "EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(clubs,'[]'::jsonb)) e WHERE e->>'source' = ?)",
      LegacyImport::HomeClubBackfill::SOURCE
    )

    count = 0
    scope.find_each do |player|
      new_clubs, removed = LegacyImport::HomeClubBackfill.revert(player.clubs)
      next if removed.empty?

      count += 1
      # Verworfene Einträge ausschreiben: ein Verein kann den Eintrag
      # zwischenzeitlich bearbeitet haben, das darf nicht unbenannt verschwinden.
      puts "  ##{player.id} #{player.last_name}, #{player.first_name}: " \
           "entfernt #{HomeClubBackfillTask.describe_entries(removed)}#{dry_run ? ' [DRY RUN]' : ''}"
      next if dry_run

      player.clubs = new_clubs
      player.save!(validate: false)
    end

    puts "\nErgebnis: #{count} Profile zurückgesetzt"
    puts 'Hinweis: ein bereits durchgeführter Merge wird hierdurch NICHT rückgängig gemacht.'
    puts '[DRY RUN] Zum Ausführen: DRY_RUN=false' if dry_run
  end
end

# Bedienung, Prüfungen und Bericht des Backfill-Tasks. Als Modul, damit die
# Fehlerpfade testbar sind und nicht als private Methoden auf Object landen
# (gleiches Muster wie PlayerMergeHelper in merge_players.rake).
module HomeClubBackfillTask
  module_function

  def parse_groups(raw)
    (raw.presence || LegacyImport::HomeClubBackfill::WRITING_GROUPS.join(','))
      .split(',').map(&:strip).reject(&:empty?)
  end

  # Streng: ein unlesbares Token wäre sonst still verschwunden, und wenn dabei
  # ALLE Tokens wegfallen, liefe der Task ohne Einschränkung über den ganzen
  # Scope. "PLAYER_IDS=#123" darf keinen Volllauf auslösen.
  def parse_player_ids(raw)
    return [] if raw.blank?

    tokens = raw.split(',').map(&:strip).reject(&:empty?)
    bad = tokens.reject { |t| t.match?(/\A\d+\z/) }
    raise ArgumentError, "PLAYER_IDS: unlesbare Angabe(n) #{bad.inspect}, erwartet werden reine Zahlen" if bad.any?
    raise ArgumentError, 'PLAYER_IDS ist gesetzt, enthält aber keine ID' if tokens.empty?

    tokens.map(&:to_i)
  end

  # Verzeichnis vorab anlegen und beschreibbar prüfen, damit ein untauglicher Pfad
  # auffällt, BEVOR geschrieben wird. Je Lauf ein eigener Unterordner, sonst liest
  # man Dateien aus zwei Läufen als eine Arbeitsliste.
  def prepare_csv_dir(raw)
    return nil if raw.blank?

    dir = File.join(raw, "lauf-#{Time.current.strftime('%Y%m%d-%H%M%S')}")
    FileUtils.mkdir_p(dir)
    raise ArgumentError, "CSV_DIR #{dir} ist nicht beschreibbar" unless File.writable?(dir)

    dir
  end

  def target_club!(player, result, ignore_club_ids)
    club = Club.find_by(id: result[:club_id])
    raise "Verein #{result[:club_id]} (Profil ##{player.id}) existiert nicht" if club.nil?

    if ignore_club_ids.include?(club.id)
      raise "Verein #{club.id} #{club.name} ist Platzhalter oder deaktiviert (Profil ##{player.id})"
    end

    club
  end

  def decision_line(player, result, club, status, dry_run)
    suffix = case status
             when :written then dry_run ? ' [DRY RUN]' : ''
             when :unchanged then ' [unverändert]'
             when :foreign_entry then ' [übersprungen: fremder Vereinseintrag]'
             when :closed_by_hand then ' [übersprungen: eigener Eintrag wurde von Hand geschlossen]'
             end

    "  [#{result[:group]}] ##{player.id} #{player.last_name}, #{player.first_name} " \
      "(#{player.birthdate}) → #{club.name} (#{club.id}) | #{result[:reason]}" \
      "#{result[:candidate_id] ? " | Dublette ##{result[:candidate_id]}" : ''}#{suffix}"
  end

  def describe_entries(entries)
    entries.map do |c|
      bis = c['valid_until'] ? ", bis #{c['valid_until']}" : ''
      "club #{c['club_id']} (von #{c['created_at']}#{bis})"
    end.join(', ')
  end

  # Was der Lauf über den eigenen Scope wissen sollte, bevor er schreibt.
  def report_scope_warnings(data, players)
    without_marker = data.profiles_without_legacy_marker(players)
    invalid = data.profiles_failing_validation(players)

    if without_marker.any?
      puts "  Hinweis: #{without_marker.size} Profil(e) ohne LIC:-Lizenz, also ohne Merkmal des Altdaten-Imports: " \
           "#{without_marker.first(10).map(&:id).join(', ')}#{without_marker.size > 10 ? ' …' : ''}"
    end
    if invalid.any?
      puts "  Hinweis: #{invalid.size} Profil(e) bestehen die Player-Validierung nicht (meist nation_id leer). " \
           'Der Task schreibt mit save!(validate: false); ein VM, der so ein Profil in der UI speichert, ' \
           'bekommt eine Validierungsmeldung.'
    end
    puts '  Hinweis: jeder Schreibvorgang erzeugt eine PaperTrail-Version (has_paper_trail auf Player).'
  end

  def report_groups(by_group, groups)
    puts "\n=== Einordnung ==="
    by_group.keys.sort.each do |group|
      rows = by_group[group]
      reasons = rows.map { |_player, result| result[:reason] }.uniq
      note = groups.include?(group) ? 'schreibend' : 'übersprungen'
      puts "  #{group}: #{rows.size.to_s.rjust(4)}  (#{note})"
      # Alle vorkommenden Begründungen zeigen: eine Gruppe kann über mehrere Wege
      # erreicht werden, eine einzelne Beispielzeile würde den Rest falsch erklären.
      reasons.first(5).each { |reason| puts "          #{reason}" }
      puts "          … #{reasons.size - 5} weitere Begründungen" if reasons.size > 5
    end
    puts "  SUMME: #{by_group.values.sum(&:size)}"
  end

  # Gruppe D braucht Nacharbeit: die Dublette ist deaktiviert und damit nicht in
  # Club#players, ein Vereins-Merge-Antrag scheitert. Nur Admin und SBK können
  # mergen. Achtung bei der Route: :id ist der ÜBERLEBENDE Master, das Duplikat
  # kommt als secondary_id in den Body.
  def report_admin_list(rows)
    return if rows.blank?

    puts "\n=== Gruppe D: Merge nur per Admin (Dublette ist deaktiviert) ==="
    puts '  Entweder das deaktivierte Profil reaktivieren und den Verein mergen lassen,'
    puts '  oder direkt: POST /admin/players/<master_id>/merge mit secondary_id=<duplikat_id>'
    puts '  (:id ist das Profil, das ERHALTEN bleibt).'
    rows.each do |player, result|
      puts "  Verein #{result[:club_id]}: Legacy-Profil ##{player.id} #{player.last_name}, #{player.first_name} " \
           "und deaktivierte Dublette ##{result[:candidate_id]}"
    end
  end

  def report_growth(club_growth)
    return if club_growth.empty?

    puts "\n=== Zuwachs in den Vereins-Spielerlisten ==="
    club_growth.sort_by { |_, count| -count }.first(15).each do |club_id, count|
      club = Club.find_by(id: club_id)
      puts "  +#{count.to_s.rjust(3)}  #{club&.name} (#{club_id})"
    end
    puts "  Vereine insgesamt: #{club_growth.size}"
  end

  def report_failures(failures)
    return if failures.blank?

    puts "\n=== Fehler (Profil übersprungen, Lauf fortgesetzt) ==="
    failures.each { |player, error| puts "  ##{player.id}: #{error.class}: #{error.message}" }
  end

  # Arbeitsliste je Verein, damit die Vereinsmanager wissen, was zu prüfen ist.
  def write_csv(dir, by_group, groups)
    rows = by_group.select { |group, _| groups.include?(group) }.values.flatten(1)
    skipped = 0

    rows.group_by { |_player, result| result[:club_id] }.each do |club_id, entries|
      if club_id.blank?
        skipped += entries.size
        next
      end

      write_club_csv(dir, club_id, entries)
    end

    puts "\nCSV-Arbeitslisten geschrieben nach #{dir}"
    puts "  #{skipped} Zeile(n) ohne Verein nicht ausgegeben" if skipped.positive?
  end

  def write_club_csv(dir, club_id, entries)
    club = Club.find_by(id: club_id)
    path = File.join(dir, "#{club_id}-#{club&.name.to_s.parameterize.presence || 'unbekannt'}.csv")

    CSV.open(path, 'w') do |csv|
      csv << %w[player_id nachname vorname geburtsdatum gruppe begruendung dubletten_id]
      entries.each do |player, result|
        csv << [player.id, player.last_name, player.first_name, player.birthdate,
                result[:group], result[:reason], result[:candidate_id]]
      end
    end
  end
end
