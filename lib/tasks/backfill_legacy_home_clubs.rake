# lib/tasks/backfill_legacy_home_clubs.rake
#
# Setzt vereinslosen Profilen aus dem Altdaten-Import 2010–2014 einen OFFENEN
# Heimatverein, damit die Vereine sie im eigenen Konto sehen und per Merge-Antrag
# mit dem lebenden Profil zusammenführen können. Entscheidungslogik in
# LegacyImport::HomeClubBackfill (DB-frei), Datenbeschaffung in
# LegacyImport::HomeClubBackfillData.
#
# Der Verein der Dublette schlägt den Lizenz-Verein: für einen Merge müssen beide
# Profile im selben Vereinskonto liegen, und wer seit 2014 gewechselt hat, ist
# heute woanders. `valid_until` bleibt leer, weil `Club#players` auf gültige
# Mitgliedschaft filtert und diese Liste auch das Duplikat-Dropdown des
# Merge-Antrags füllt.
#
# Dry-Run (Standard):
#   bundle exec rails players:backfill_legacy_home_clubs
# Nur die Dubletten-Fälle live schreiben:
#   bundle exec rails players:backfill_legacy_home_clubs DRY_RUN=false GROUPS=A,D
# Einzelfall prüfen:
#   bundle exec rails players:backfill_legacy_home_clubs PLAYER_IDS=30211
# Arbeitslisten je Verein als CSV:
#   bundle exec rails players:backfill_legacy_home_clubs CSV_DIR=tmp/backfill
#
# Rücknahme (entfernt ausschließlich die eigenen Einträge):
#   bundle exec rails players:rollback_legacy_home_clubs DRY_RUN=false

require 'csv'

namespace :players do
  desc 'Setzt vereinslosen Legacy-Profilen einen offenen Heimatverein (Merge-Vorbereitung). DRY_RUN=false zum Ausführen.'
  task backfill_legacy_home_clubs: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    groups = (ENV['GROUPS'].presence || LegacyImport::HomeClubBackfill::WRITING_GROUPS.join(',')).split(',').map(&:strip)
    only_ids = ENV['PLAYER_IDS'].to_s.split(',').filter_map { |s| s.strip.to_i.nonzero? }

    puts "=== Legacy-Heimatvereine nachziehen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "Schreibende Gruppen: #{groups.join(', ')}"

    data = LegacyImport::HomeClubBackfillData.new
    puts "Ignorierte Platzhalter-/deaktivierte Vereine: #{data.ignore_club_ids.size}"

    scope = data.scope
    scope = scope.where(id: only_ids) if only_ids.any?
    players = scope.to_a.sort_by { |p| [p.last_name.to_s, p.first_name.to_s] }
    puts "Profile im Scope: #{players.size}\n"

    by_group = Hash.new { |h, k| h[k] = [] }
    club_growth = Hash.new(0)
    written = 0

    players.each do |player|
      result = data.decide_for(player)
      by_group[result[:group]] << [player, result]
      next unless result[:club_id] && groups.include?(result[:group])

      club = backfill_target_club!(player, result, data)
      entry = LegacyImport::HomeClubBackfill.build_entry(
        club_id: club.id, created_at: data.earliest_license_start(player, club.id)
      )
      new_clubs, changed = LegacyImport::HomeClubBackfill.apply(player.clubs, entry)

      puts "  [#{result[:group]}] ##{player.id} #{player.last_name}, #{player.first_name} " \
           "(#{player.birthdate}) → #{club.name} (#{club.id}) | #{result[:reason]}" \
           "#{result[:candidate_id] ? " | Dublette ##{result[:candidate_id]}" : ''}" \
           "#{changed ? '' : ' [unverändert]'}#{dry_run && changed ? ' [DRY RUN]' : ''}"
      next unless changed

      written += 1
      club_growth[club.id] += 1
      next if dry_run

      player.clubs = new_clubs
      player.save!(validate: false)
    end

    backfill_report_groups(by_group, groups)
    backfill_report_admin_list(by_group['D'])
    backfill_report_growth(club_growth)
    backfill_write_csv(by_group, groups) if ENV['CSV_DIR'].present?

    puts "\nErgebnis: #{written} Profile mit neuem Heimatverein in #{club_growth.size} Vereinen"
    puts '[DRY RUN] Zum Ausführen: DRY_RUN=false' if dry_run
  end

  desc 'Entfernt die vom Backfill gesetzten Heimatvereine wieder. DRY_RUN=false zum Ausführen.'
  task rollback_legacy_home_clubs: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Legacy-Heimatvereine zurücknehmen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    # Auch bereits gemergte Master erfassen: merge_into! hängt den Eintrag über
    # _merge_clubs an den Master, der Marker wandert also mit.
    scope = Player.where(
      "EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(clubs,'[]'::jsonb)) e WHERE e->>'source' = ?)",
      LegacyImport::HomeClubBackfill::SOURCE
    )

    count = 0
    scope.find_each do |player|
      new_clubs, changed = LegacyImport::HomeClubBackfill.revert(player.clubs)
      next unless changed

      count += 1
      puts "  ##{player.id} #{player.last_name}, #{player.first_name}: " \
           "#{player.clubs.size} → #{new_clubs.size} Einträge#{dry_run ? ' [DRY RUN]' : ''}"
      next if dry_run

      player.clubs = new_clubs
      player.save!(validate: false)
    end

    puts "\nErgebnis: #{count} Profile zurückgesetzt"
    puts '[DRY RUN] Zum Ausführen: DRY_RUN=false' if dry_run
  end

  # Zielverein auflösen und die beiden Abbruchbedingungen prüfen: ein fehlender
  # oder ein Platzhalter-Verein darf nie geschrieben werden.
  def backfill_target_club!(player, result, data)
    club = Club.find_by(id: result[:club_id])
    raise "Verein #{result[:club_id]} (Profil ##{player.id}) existiert nicht" if club.nil?
    raise "Verein #{club.id} #{club.name} ist ein Platzhalter (Profil ##{player.id})" if data.ignore_club_ids.include?(club.id)

    club
  end

  def backfill_report_groups(by_group, groups)
    puts "\n=== Einordnung ==="
    by_group.keys.sort.each do |group|
      note = groups.include?(group) ? 'schreibend' : "übersprungen: #{by_group[group].first&.last&.dig(:reason)}"
      puts "  #{group}: #{by_group[group].size.to_s.rjust(4)}  (#{note})"
    end
    puts "  SUMME: #{by_group.values.sum(&:size)}"
  end

  # Gruppe D braucht Nacharbeit: die Dublette ist deaktiviert und damit nicht in
  # Club#players, ein Vereins-Merge-Antrag scheitert. Nur Admin/SBK können mergen.
  def backfill_report_admin_list(rows)
    return if rows.blank?

    puts "\n=== Gruppe D: Merge nur per Admin (Dublette ist deaktiviert) ==="
    rows.each do |player, result|
      puts "  ##{player.id} #{player.last_name}, #{player.first_name} → Verein #{result[:club_id]}: " \
           "Dublette ##{result[:candidate_id]} reaktivieren oder POST /admin/players/#{result[:candidate_id]}/merge"
    end
  end

  def backfill_report_growth(club_growth)
    return if club_growth.empty?

    puts "\n=== Zuwachs in den Vereins-Spielerlisten ==="
    club_growth.sort_by { |_, count| -count }.first(15).each do |club_id, count|
      club = Club.find_by(id: club_id)
      puts "  +#{count.to_s.rjust(3)}  #{club&.name} (#{club_id}), aktuell #{club&.players&.size}"
    end
    puts "  Vereine insgesamt: #{club_growth.size}"
  end

  # Arbeitsliste je Verein, damit die Vereinsmanager wissen, was zu prüfen ist.
  def backfill_write_csv(by_group, groups)
    dir = ENV.fetch('CSV_DIR')
    FileUtils.mkdir_p(dir)
    rows = by_group.select { |group, _| groups.include?(group) }.values.flatten(1)
    rows.group_by { |_, result| result[:club_id] }.each do |club_id, entries|
      next if club_id.blank?

      club = Club.find_by(id: club_id)
      path = File.join(dir, "#{club_id}-#{club&.name.to_s.parameterize}.csv")
      CSV.open(path, 'w') do |csv|
        csv << %w[player_id nachname vorname geburtsdatum gruppe begruendung dubletten_id]
        entries.each do |player, result|
          csv << [player.id, player.last_name, player.first_name, player.birthdate,
                  result[:group], result[:reason], result[:candidate_id]]
        end
      end
    end
    puts "\nCSV-Arbeitslisten geschrieben nach #{dir}"
  end
end
