# lib/tasks/merge_players.rake
#
# Findet und mergt doppelte Spielereinträge anhand Name + Geburtsdatum.
# Gemergt wird jeweils in den Datensatz mit der KLEINSTEN ID; alle übrigen
# Datensätze der Gruppe werden dort verlustfrei zusammengeführt (Clubs, Lizenzen,
# Spieleinsätze, Transfers, Sperren etc. – siehe Player#merge_into!).
#
# Als Duplikat gelten Spieler mit gleichem Namen (case-insensitive) UND einem
# Geburtsdatum, das entweder identisch ist, sich um höchstens einen Tag
# unterscheidet oder in genau einer Ziffer abweicht (Tippfehler, z. B. Jahr
# 1872 statt 1972). Das verbleibende Geburtsdatum wird aufgelöst:
#   - weicht nur der Tag ab  → das frühere Datum
#   - weicht das Jahr ab     → das plausiblere (realistisches Alter)
#
# Dry-Run (Standard):
#   bundle exec rails players:merge_duplicates
#
# Ausführen:
#   bundle exec rails players:merge_duplicates DRY_RUN=false [USER_ID=<id>]

namespace :players do
  desc 'Doppelte Spieler in den Datensatz mit kleinster ID zusammenlegen. DRY_RUN=false zum Ausführen.'
  task merge_duplicates: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    user_id = ENV['USER_ID'].presence&.to_i
    puts "=== Spieler-Merge #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts

    groups = PlayerMergeHelper.find_duplicate_groups
    puts "#{groups.size} Duplikat-Gruppe(n) gefunden.\n\n"

    merged = 0
    skipped = 0
    errors = 0
    stranded = 0

    groups.each_with_index do |(survivor, secondaries), idx|
      survivor = Player.find(survivor.id)
      resolved = PlayerMergeHelper.resolve_birthdate([survivor] + secondaries)

      puts "--- Gruppe #{idx + 1}: #{survivor.last_name}, #{survivor.first_name} ---"
      puts "  BEHALTEN: ##{survivor.id} | Geburtsdatum #{survivor.birthdate}" \
           "#{resolved != survivor.birthdate ? " → #{resolved}" : ''}"

      # Geburtsdatum einmal pro Gruppe persistieren (unabhängig vom Erfolg der
      # einzelnen Merges), damit ein zurückgerolltes Merge das Datum nicht
      # dauerhaft unkorrigiert lässt.
      if !dry_run && survivor.birthdate != resolved
        survivor.birthdate = resolved
        survivor.save!(validate: false)
      end

      secondaries.each do |sec|
        puts "  MERGE:    ##{sec.id} | Geburtsdatum #{sec.birthdate}"
        sec = Player.find_by(id: sec.id)
        unless sec && Player.exists?(survivor.id)
          puts "    SKIP ##{sec&.id}: Datensatz existiert nicht mehr"
          skipped += 1
          next
        end

        conflicts = PlayerMergeHelper.games_with_both(survivor.id, sec.id)
        if conflicts.any?
          puts "    SKIP ##{sec.id}: beide IDs in #{conflicts.size} Spiel(en) (#{conflicts.map(&:id).join(', ')})"
          skipped += 1
          next
        end

        game_count = Game.referencing_player(sec.id).count
        puts "    ##{sec.id}: Spiele #{game_count}, Clubs #{sec.clubs&.size || 0}, " \
             "Lizenzen #{sec.licenses&.size || 0}, Transfers #{Transfer.where(player_id: sec.id).count}"

        if dry_run
          puts "    => würde ##{sec.id} in ##{survivor.id} mergen [DRY RUN]"
          merged += 1
        else
          begin
            left = sec.merge_into!(survivor, user_id)
            merged += 1
            if left.any?
              stranded += left.size
              details = left.map { |a| "#{a[:type]} ##{a[:id]}" }.join(', ')
              puts "    => gemergt – #{left.size} Verknüpfung(en) blieben am Zweitprofil ##{sec.id}: #{details}"
            else
              puts "    => gemergt."
            end
          rescue StandardError => e
            puts "    FEHLER ##{sec.id}: #{e.class}: #{e.message}"
            puts "      #{e.backtrace.first(3).join("\n      ")}" if e.backtrace
            errors += 1
          end
        end
      end
      puts
    end

    summary = "Ergebnis: #{merged} #{dry_run ? 'zu mergen' : 'gemergt'}, #{skipped} übersprungen (Regel)"
    summary += ", #{errors} FEHLER" if errors.positive?
    summary += ", #{stranded} Verknüpfung(en) am Zweitprofil belassen" if stranded.positive?
    puts summary
    puts "[DRY RUN] Zum Ausführen: rails players:merge_duplicates DRY_RUN=false" if dry_run

    # Nicht-null Exit-Code, damit echte Fehler nicht in einem grün wirkenden Lauf untergehen.
    exit 1 if errors.positive?
  end
end

module PlayerMergeHelper
  module_function

  # Plausibles Geburtsjahr → Alter zwischen diesen Grenzen (zum Erkennen von
  # Jahres-Tippfehlern wie 1872 statt 1972).
  PLAUSIBLE_MIN_AGE = 3
  PLAUSIBLE_MAX_AGE = 100

  # Duplikat-Gruppen: gleicher Name + ähnliches Geburtsdatum.
  # Gibt [[survivor(kleinste ID), [secondary, ...]], ...] zurück.
  # Nur aktive, noch nicht zusammengeführte Spieler werden berücksichtigt.
  def find_duplicate_groups
    scope = Player.where(merged_into_id: nil, deactivated_at: nil)
    by_name = scope.group_by do |p|
      [p.first_name.to_s.strip.downcase, p.last_name.to_s.strip.downcase]
    end

    groups = []
    by_name.each do |(first, last), players|
      next if players.size < 2
      next if first.blank? && last.blank?

      cluster_by_birthdate(players).each do |cluster|
        next if cluster.size < 2

        sorted = cluster.sort_by(&:id)
        groups << [sorted.first, sorted[1..]]
      end
    end
    groups
  end

  # Spieler eines Namens anhand Geburtsdatum-Ähnlichkeit in zusammenhängende
  # Komponenten gruppieren. Spieler ohne parsbares Geburtsdatum bleiben außen vor.
  def cluster_by_birthdate(players)
    dated = players.map { |p| [p, parse_date(p.birthdate)] }.select { |_, d| d }
    n = dated.size
    return [] if n < 2

    adjacency = Array.new(n) { [] }
    (0...n).each do |i|
      ((i + 1)...n).each do |j|
        next unless similar_dates?(dated[i][1], dated[j][1])

        adjacency[i] << j
        adjacency[j] << i
      end
    end

    connected_components(adjacency).map { |component| component.map { |k| dated[k][0] } }
  end

  def connected_components(adjacency)
    seen = Array.new(adjacency.size, false)
    components = []
    adjacency.each_index do |start|
      next if seen[start]

      stack = [start]
      component = []
      until stack.empty?
        node = stack.pop
        next if seen[node]

        seen[node] = true
        component << node
        adjacency[node].each { |m| stack << m unless seen[m] }
      end
      components << component
    end
    components
  end

  # Geburtsdaten gelten als „gleich genug": identisch, um höchstens einen Tag
  # abweichend oder in genau einer Ziffer verschieden.
  def similar_dates?(date_a, date_b)
    return true if date_a == date_b
    return true if (date_a - date_b).abs <= 1

    one_digit_diff?(date_a.iso8601, date_b.iso8601)
  end

  def one_digit_diff?(str_a, str_b)
    return false unless str_a.length == str_b.length

    diff_positions = (0...str_a.length).reject { |i| str_a[i] == str_b[i] }
    diff_positions.size == 1 &&
      str_a[diff_positions.first].match?(/\d/) && str_b[diff_positions.first].match?(/\d/)
  end

  # Verbleibendes Geburtsdatum: plausible Jahre bevorzugen (Jahres-Tippfehler
  # aussortieren), unter den Kandidaten das früheste Datum wählen. iso8601-String.
  def resolve_birthdate(players)
    dates = players.map { |p| parse_date(p.birthdate) }.compact.uniq
    return players.first.birthdate if dates.empty?

    current_year = Date.current.year
    plausible = dates.select do |d|
      (current_year - d.year).between?(PLAUSIBLE_MIN_AGE, PLAUSIBLE_MAX_AGE)
    end
    (plausible.presence || dates).min.iso8601
  end

  # Spiele, in denen BEIDE IDs vorkommen → Konflikt (derselbe Spieler doppelt in
  # einer Aufstellung), nicht automatisch mergebar.
  def games_with_both(id_a, id_b)
    (Game.referencing_player(id_a).to_a & Game.referencing_player(id_b).to_a).select do |game|
      game.player_in_lineup?(id_a) && game.player_in_lineup?(id_b)
    end
  end

  def parse_date(str)
    return nil if str.blank?

    Date.parse(str.to_s[0, 10])
  rescue ArgumentError, TypeError
    nil
  end
end
