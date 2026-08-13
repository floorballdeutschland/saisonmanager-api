# Entfernt die Gast-Einträge aus clubs.game_operations_hash.
#
# HINTERGRUND
#
# Der Hash trug pro Verein einen Heim-Eintrag (`home_game_operation: true`) und
# optional weitere auf fremde Spielbetriebe. Diese Gast-Einträge hat die
# Anwendung an keiner Stelle geschrieben – einzige Quelle war der Altdaten-Import
# 2010–2014 (lib/tasks/import_legacy_data.rake) – und sie wurden auch nicht
# nachgeführt, wenn eine Mannschaft die Liga wechselte.
#
# Bis Release 1.67.1 entschieden sie über Rechte (Vereinslisten,
# Vereinsstammdaten, Spielerlisten, Lizenzdokumente, Spielersperren). Das ist
# umgestellt: Maßgeblich sind Heimat-Spielbetrieb, Vereins-Freigabe
# (StateAssociationRelease) und die Liga. Mit dieser Version fällt das Konzept
# ganz weg – der Hash trägt nur noch den Heimat-Eintrag.
#
# Ein erster Lauf am 04.08.2026 entfernte auf Produktion die 181 Einträge ohne
# Grundlage. Dieser Task räumt den Rest ab; er unterscheidet nicht mehr nach
# Deckung, weil ein Gast-Eintrag nach dem Wegfall des Konzepts nirgends mehr
# gelesen wird.
#
# Beide Tasks sind per DEFAULT Dry-Run. Scharfschalten mit DRY_RUN=false.
#
#   rake cleanup:guest_game_operations_report                  # nur lesend
#   rake cleanup:guest_game_operations                         # Vorschau
#   DRY_RUN=false rake cleanup:guest_game_operations           # ausführen
#
# Der Heim-Eintrag wird nie angefasst.

namespace :cleanup do
  # Alle (Verein, Gast-Spielbetrieb)-Paare. `Club#additional_game_operation_ids`
  # gibt es nicht mehr, deshalb hier direkt über den Hash.
  def guest_go_pairs
    Club.where("clubs.game_operations_hash @> '[{\"home_game_operation\": false}]'")
        .order(:name)
        .flat_map do |club|
      club.game_operations_hash
          .reject { |entry| entry['home_game_operation'] }
          .map { |entry| { club: club, go_id: entry['game_operation_id'].to_i } }
    end
  end

  desc 'Übersicht über die Gast-Einträge im game_operations_hash (nur lesend)'
  task guest_game_operations_report: :environment do
    pairs = guest_go_pairs

    puts "Gast-Einträge insgesamt: #{pairs.size} bei #{pairs.map { |p| p[:club].id }.uniq.size} Vereinen"

    # `next`, nicht `return`: Ein `return` im Rake-Block wirft LocalJumpError.
    # Faellt erst auf, wenn nichts mehr zu bereinigen ist – also genau nach
    # einem erfolgreichen Lauf.
    next if pairs.empty?

    go_names = GameOperation.pluck(:id, :name).to_h
    puts "\nNach Empfänger-Spielbetrieb:"
    pairs.group_by { |p| p[:go_id] }.sort_by { |_, v| -v.size }.each do |go_id, group|
      puts format('  GO %<go>-4s %<name>-42s %<count>3d Vereine',
                  go: go_id, name: go_names[go_id].to_s.strip[0, 41], count: group.size)
    end
  end

  desc 'Entfernt die Gast-Einträge aus clubs.game_operations_hash. DRY_RUN=false zum Ausführen.'
  task guest_game_operations: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Gast-Einträge bereinigen #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="

    by_club = guest_go_pairs.group_by { |p| p[:club].id }
    if by_club.empty?
      puts 'Nichts zu tun.'
      next
    end

    removed_entries = 0
    changed_clubs = 0
    skipped = []

    by_club.each do |club_id, pairs|
      club = pairs.first[:club]
      before = club.game_operations_hash
      after = before.select { |entry| entry['home_game_operation'] }

      # Sicherheitsnetz: Der Heim-Eintrag muss übrig bleiben. Ein Verein ohne ihn
      # wäre über die Oberfläche nicht mehr auffindbar – die Vereinslisten matchen
      # per jsonb genau darauf. Fehlt er schon vorher, liegt ein Datenfehler vor
      # und der Verein wird übersprungen statt beschädigt.
      if after.empty?
        skipped << "#{club.name} (#{club_id}): kein Heim-Eintrag vorhanden – übersprungen"
        next
      end

      puts format('  %<club>-34s entfernt GO %<gos>s',
                  club: club.name.to_s[0, 33], gos: pairs.map { |p| p[:go_id] }.sort.join(', '))
      # Protokoll zum Zurückrollen, bevor geschrieben wird.
      puts "     ROLLBACK: Club.find(#{club_id}).update_column(:game_operations_hash, #{before.to_json})"

      club.update_column(:game_operations_hash, after) unless dry_run
      removed_entries += pairs.size
      changed_clubs += 1
    end

    skipped.each { |m| puts "  #{m}" }

    puts "\n#{dry_run ? 'DRY RUN – nichts geschrieben.' : 'Geschrieben.'} " \
         "#{removed_entries} Einträge bei #{changed_clubs} Vereinen" \
         "#{skipped.any? ? ", #{skipped.size} übersprungen" : ''}."
  end
end
