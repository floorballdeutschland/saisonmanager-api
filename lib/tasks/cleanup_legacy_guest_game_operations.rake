# Bereinigt veraltete Gast-Einträge aus clubs.game_operations_hash.
#
# HINTERGRUND
#
# Der Hash trägt pro Verein einen Heim-Eintrag (`home_game_operation: true`) und
# optional weitere auf fremde Spielbetriebe. Diese Gast-Einträge schreibt die
# Anwendung an keiner Stelle – einzige Quelle ist der Altdaten-Import 2010–2014
# (lib/tasks/import_legacy_data.rake) – und sie werden auch nicht nachgeführt,
# wenn eine Mannschaft die Liga wechselt. Auf Produktion waren am 04.08.2026
# 183 von 220 Gast-Einträgen durch keine aktuelle Liga und keine
# Vereins-Freigabe mehr gedeckt.
#
# Bis Release 1.67.1 entschieden diese Einträge über Rechte (Vereinslisten,
# Vereinsstammdaten, Spielerlisten, Lizenzdokumente, Spielersperren). Das ist
# umgestellt: Maßgeblich sind jetzt Heimat-Spielbetrieb, Vereins-Freigabe und
# die Liga. Die Einträge sind damit wirkungslose Datenreste – dieser Task räumt
# sie weg, damit sie keine künftige Auswertung mehr in die Irre führen.
#
# Alle Tasks sind per DEFAULT Dry-Run. Scharfschalten mit DRY_RUN=false.
#
#   rake cleanup:guest_game_operations_report                  # nur lesend
#   rake cleanup:guest_game_operations                         # Vorschau
#   DRY_RUN=false rake cleanup:guest_game_operations           # ausführen
#
# Der Heim-Eintrag wird nie angefasst. Ein Gast-Eintrag bleibt stehen, wenn er
# gedeckt ist – siehe #covered_guest_entry? unten.

namespace :cleanup do
  # Verein hat in der angegebenen Saison eine Mannschaft in einer Liga dieses
  # Spielbetriebs. SG-Partnervereine zählen über Team#all_club_ids mit.
  def guest_go_coverage(season_id)
    coverage = Hash.new { |h, k| h[k] = Set.new }
    Team.joins(:league)
        .where(leagues: { season_id: season_id })
        .pluck(:club_id, :syndicate_clubs, 'leagues.game_operation_id')
        .each do |club_id, syndicate, go_id|
      ([club_id] + Array(syndicate)).compact.uniq.each { |cid| coverage[cid] << go_id }
    end
    coverage
  end

  # Freigaben der laufenden Saison: freigebender Landesverband -> Empfänger-Spielbetriebe.
  def guest_go_releases
    StateAssociationRelease.current_season
                           .pluck(:grantor_state_association_id, :recipient_game_operation_id)
                           .group_by(&:first)
                           .transform_values { |rows| rows.map(&:last).to_set }
  end

  # Alle (Verein, Gast-Spielbetrieb)-Paare mit Bewertung.
  def guest_go_pairs
    season = Setting.current_season_id
    coverage = guest_go_coverage(season)
    releases = guest_go_releases

    pairs = []
    Club.where("clubs.game_operations_hash @> '[{\"home_game_operation\": false}]'").find_each do |club|
      home = club.main_game_operation_id
      club.additional_game_operation_ids.each do |go_id|
        # Ein Eintrag, der denselben Spielbetrieb wie der Heim-Eintrag nennt, ist
        # redundant, aber kein Fremdzugriff – ebenfalls stehen lassen.
        next if go_id == home

        pairs << {
          club: club,
          go_id: go_id,
          by_league: coverage[club.id].include?(go_id),
          by_release: releases[club.state_association_id]&.include?(go_id) || false
        }
      end
    end
    pairs
  end

  def covered_guest_entry?(pair)
    pair[:by_league] || pair[:by_release]
  end

  desc 'Übersicht über veraltete Gast-Einträge im game_operations_hash (nur lesend)'
  task guest_game_operations_report: :environment do
    pairs = guest_go_pairs
    stale = pairs.reject { |p| covered_guest_entry?(p) }

    puts "Saison #{Setting.current_season_id}"
    puts "Gast-Einträge insgesamt:                 #{pairs.size}"
    puts "  durch eine aktuelle Liga gedeckt:      #{pairs.count { |p| p[:by_league] }}"
    puts "  durch eine Vereins-Freigabe gedeckt:   #{pairs.count { |p| !p[:by_league] && p[:by_release] }}"
    puts "  ohne Grundlage (würden entfallen):     #{stale.size} bei #{stale.map { |p| p[:club].id }.uniq.size} Vereinen"

    return if stale.empty?

    go_names = GameOperation.pluck(:id, :name).to_h
    puts "\nNach Empfänger-Spielbetrieb:"
    stale.group_by { |p| p[:go_id] }.sort_by { |_, v| -v.size }.each do |go_id, group|
      puts format('  GO %<go>-4s %<name>-42s %<count>3d Vereine',
                  go: go_id, name: go_names[go_id].to_s.strip[0, 41], count: group.size)
    end
  end

  desc 'Entfernt veraltete Gast-Einträge aus clubs.game_operations_hash. DRY_RUN=false zum Ausführen.'
  task guest_game_operations: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Gast-Einträge bereinigen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    stale_by_club = guest_go_pairs.reject { |p| covered_guest_entry?(p) }.group_by { |p| p[:club].id }
    if stale_by_club.empty?
      puts 'Nichts zu tun.'
      next
    end

    removed_entries = 0
    changed_clubs = 0
    skipped = []

    stale_by_club.each do |club_id, pairs|
      club = pairs.first[:club]
      drop = pairs.map { |p| p[:go_id] }.to_set
      before = club.game_operations_hash
      after = before.reject do |entry|
        !entry['home_game_operation'] && drop.include?(entry['game_operation_id'].to_i)
      end

      # Sicherheitsnetze: Weder darf der Hash leer werden, noch der Heim-Eintrag
      # verschwinden. Beides kann nach der Filterung oben nicht passieren – wenn
      # doch, liegt ein Datenfehler vor und der Verein wird übersprungen statt
      # beschädigt.
      if after.empty? || after.none? { |e| e['home_game_operation'] }
        skipped << "#{club.name} (#{club_id}): Hash wäre danach ohne Heim-Eintrag – übersprungen"
        next
      end

      puts format('  %<club>-34s entfernt GO %<gos>s',
                  club: club.name.to_s[0, 33], gos: drop.to_a.sort.join(', '))
      # Protokoll zum Zurückrollen, bevor geschrieben wird.
      puts "     ROLLBACK: Club.find(#{club_id}).update_column(:game_operations_hash, #{before.to_json})"

      club.update_column(:game_operations_hash, after) unless dry_run
      removed_entries += drop.size
      changed_clubs += 1
    end

    skipped.each { |m| puts "  #{m}" }

    puts "\n#{dry_run ? 'DRY RUN – nichts geschrieben.' : 'Geschrieben.'} " \
         "#{removed_entries} Einträge bei #{changed_clubs} Vereinen" \
         "#{skipped.any? ? ", #{skipped.size} übersprungen" : ''}."
  end
end
