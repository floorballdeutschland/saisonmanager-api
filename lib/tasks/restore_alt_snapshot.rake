# lib/tasks/restore_alt_snapshot.rake
#
# Stellt Spielerdaten anhand eines Abgleichs mit dem Alt-System wieder her
# (Vorfall 2026-07-13/Import-Lücke, siehe CHANGELOG):
#   1. Heimatmitgliedschaften, die von players:close_legacy_memberships bzw.
#      players:fix_club_valid_until fälschlich geschlossen wurden
#      (valid_until wird entfernt, Alt-System-Stand "offen").
#   2. Geburtsdaten, die im Alt-System nach dem Import-Dump gepflegt wurden
#      und den Umzug nicht geschafft haben.
#
# Die Daten-Datei enthält personenbezogene Daten und liegt bewusst NICHT im
# Repo. Format (JSON):
#   {
#     "home_repairs":      [{ "player_id": 1, "club_id": 2,
#                             "expected_created_at": null,
#                             "expected_valid_until": "2015-..." }],
#     "birthdate_repairs": [{ "player_id": 1, "alt": "1990-01-01",
#                             "expected_neu": null }]
#   }
#
# Jede Korrektur wird nur angewendet, wenn der aktuelle Prod-Wert noch dem
# erwarteten (korrupten) Stand entspricht — zwischenzeitliche echte Änderungen
# (z. B. VM-Deaktivierung, manuelle Korrektur) werden übersprungen und
# protokolliert. Der Task ist dadurch idempotent und gefahrlos wiederholbar.
#
# Dry-Run (Standard):
#   bundle exec rails players:restore_alt_snapshot DATA_FILE=/tmp/repair.json
# Ausführen:
#   bundle exec rails players:restore_alt_snapshot DATA_FILE=/tmp/repair.json DRY_RUN=false

namespace :players do
  desc 'Stellt Heimatmitgliedschaften/Geburtsdaten aus Alt-System-Abgleich wieder her. DATA_FILE=…, DRY_RUN=false zum Ausführen.'
  task restore_alt_snapshot: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    data_file = ENV['DATA_FILE']
    abort 'DATA_FILE nicht gesetzt' if data_file.blank?
    abort "Datei nicht gefunden: #{data_file}" unless File.exist?(data_file)

    data = JSON.parse(File.read(data_file))
    home_repairs = Array(data['home_repairs'])
    birthdate_repairs = Array(data['birthdate_repairs'])

    puts "=== Wiederherstellung aus Alt-System-Abgleich #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts "#{home_repairs.size} Heimat-Reparaturen, #{birthdate_repairs.size} Geburtsdatum-Reparaturen in #{data_file}"
    puts

    stats = Hash.new(0)

    # --- 1. Heimatmitgliedschaften wieder öffnen -----------------------------
    home_repairs.group_by { |r| r['player_id'] }.each do |player_id, repairs|
      player = Player.find_by(id: player_id)
      if player.nil?
        puts "  ##{player_id}: SKIP – Spieler nicht gefunden"
        stats[:home_player_missing] += repairs.size
        next
      end

      changed = false
      repairs.each do |r|
        entry = (player.clubs || []).find do |c|
          c['home_club'] == true &&
            c['club_id'].to_s == r['club_id'].to_s &&
            c['created_at'] == r['expected_created_at'] &&
            c['valid_until'] == r['expected_valid_until']
        end

        if entry.nil?
          puts "  ##{player_id} #{player.last_name}: SKIP club #{r['club_id']} – " \
               'Eintrag nicht mehr im erwarteten Zustand (zwischenzeitlich geändert oder bereits repariert)'
          stats[:home_skipped] += 1
          next
        end

        entry.delete('valid_until')
        changed = true
        stats[:home_restored] += 1
        puts "  ##{player_id} #{player.last_name}, #{player.first_name}: club #{r['club_id']} " \
             "wieder offen (war #{r['expected_valid_until']})#{dry_run ? ' [DRY RUN]' : ''}"
      end

      if changed && !dry_run
        player.save!(validate: false)
        stats[:home_players_saved] += 1
      end
    end

    puts

    # --- 2. Geburtsdaten zurückspielen ---------------------------------------
    birthdate_repairs.each do |r|
      player = Player.find_by(id: r['player_id'])
      if player.nil?
        puts "  ##{r['player_id']}: SKIP – Spieler nicht gefunden"
        stats[:birthdate_player_missing] += 1
        next
      end

      current = player.birthdate&.iso8601
      expected = r['expected_neu']
      unless current == expected
        puts "  ##{r['player_id']} #{player.last_name}: SKIP Geburtsdatum – " \
             "aktuell #{current.inspect}, erwartet #{expected.inspect} (zwischenzeitlich geändert)"
        stats[:birthdate_skipped] += 1
        next
      end

      puts "  ##{r['player_id']} #{player.last_name}, #{player.first_name}: Geburtsdatum " \
           "#{current.inspect} → #{r['alt']}#{dry_run ? ' [DRY RUN]' : ''}"
      unless dry_run
        player.birthdate = r['alt']
        player.save!(validate: false)
      end
      stats[:birthdate_restored] += 1
    end

    puts
    puts '=== Ergebnis ==='
    stats.sort.each { |k, v| puts "  #{k}: #{v}" }
    puts '[DRY RUN] Zum Ausführen: DRY_RUN=false anhängen' if dry_run
  end
end
