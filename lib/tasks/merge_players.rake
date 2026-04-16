# lib/tasks/merge_players.rake
#
# Findet und mergt doppelte Spielereinträge anhand Name + Geburtsdatum (±1 Tag).
# Behalte den Datensatz mit der höheren ID (neuerer Eintrag).
#
# Dry-Run (Standard):
#   bundle exec rails players:merge_duplicates
#
# Ausführen:
#   bundle exec rails players:merge_duplicates DRY_RUN=false

namespace :players do
  desc 'Doppelte Spieler zusammenlegen (Name + Geburtsdatum ±1 Tag). DRY_RUN=false zum Ausführen.'
  task merge_duplicates: :environment do
    dry_run = ENV['DRY_RUN'] != 'false'
    puts "=== Spieler-Merge #{dry_run ? '[DRY RUN]' : '[LIVE]'} ==="
    puts

    pairs = PlayerMergeHelper.find_duplicate_pairs
    puts "#{pairs.size} Duplikat-Paar(e) gefunden.\n\n"

    merged = 0
    skipped = 0

    pairs.each_with_index do |(old_p, new_p), idx|
      puts "--- Paar #{idx + 1} ---"
      puts "  ALT: ##{old_p.id} #{old_p.last_name}, #{old_p.first_name} | #{old_p.birthdate} | security_id=#{old_p.security_id}"
      puts "  NEU: ##{new_p.id} #{new_p.last_name}, #{new_p.first_name} | #{new_p.birthdate} | security_id=#{new_p.security_id}"

      # Prüfen ob beide Spieler noch existieren (könnten aus früherem Merge weg sein)
      unless Player.exists?(old_p.id)
        puts "  SKIP: Spieler ##{old_p.id} (ALT) existiert nicht mehr (bereits gemergt?)"
        skipped += 1
        next
      end
      unless Player.exists?(new_p.id)
        puts "  SKIP: Spieler ##{new_p.id} (NEU) existiert nicht mehr (bereits gemergt?)"
        skipped += 1
        next
      end

      # Frisch aus DB laden damit keine eingefrorenen/veralteten Objekte verwendet werden
      old_p = Player.find(old_p.id)
      new_p = Player.find(new_p.id)

      conflicts = PlayerMergeHelper.games_with_both(old_p.id, new_p.id)
      if conflicts.any?
        puts "  KONFLIKT: Beide IDs in #{conflicts.size} Spiel(en) — übersprungen"
        puts "  Game-IDs: #{conflicts.map(&:id).join(', ')}"
        skipped += 1
        next
      end

      game_count     = PlayerMergeHelper.affected_games(old_p.id).count
      transfer_count = Transfer.where(player_id: old_p.id).count

      puts "  Betroffene Spiele: #{game_count}, Transfers: #{transfer_count}"
      puts "  Clubs alt: #{old_p.clubs&.size || 0}, Lizenzen alt: #{old_p.licenses&.size || 0}"
      puts "  Clubs neu: #{new_p.clubs&.size || 0}, Lizenzen neu: #{new_p.licenses&.size || 0}"

      if dry_run
        puts "  => Würde ##{old_p.id} in ##{new_p.id} mergen [DRY RUN]"
      else
        begin
          ActiveRecord::Base.transaction do
            PlayerMergeHelper.merge!(old_p, new_p)
          end
          puts "  => Gemergt."
          merged += 1
        rescue => e
          puts "  FEHLER: #{e.class}: #{e.message}"
          skipped += 1
        end
      end
      puts
    end

    puts "Ergebnis: #{merged} gemergt, #{skipped} übersprungen"
    puts "[DRY RUN] Zum Ausführen: rails players:merge_duplicates DRY_RUN=false" if dry_run
  end
end

module PlayerMergeHelper
  module_function

  # Alle Duplikat-Paare: gleicher Name (case-insensitive) + Geburtsdatum ±1 Tag.
  # Gibt [[old_player, new_player], ...] zurück (old = kleinere ID).
  PLACEHOLDER_SECURITY_ID = 'uuid_generate_v4()'.freeze

  def find_duplicate_pairs
    groups = Player.all.group_by do |p|
      [p.first_name.to_s.strip.downcase, p.last_name.to_s.strip.downcase]
    end

    pairs = []
    groups.each do |(first, last), players|
      next if players.size < 2
      # Platzhalter-Datensätze (leerer Name oder Dummy-Geburtsdatum 1900-01-01) überspringen
      next if (first.blank? || first == '-') && (last.blank? || last == '-')

      players.combination(2) do |a, b|
        date_a = parse_date(a.birthdate)
        date_b = parse_date(b.birthdate)
        next unless date_a && date_b
        next unless (date_a - date_b).abs <= 1

        # Standard: kleinere ID = alt, größere = neu
        old_p, new_p = [a, b].sort_by(&:id)

        # Ausnahme: hat der "neue" Datensatz eine kaputte security_id,
        # der "alte" aber eine echte UUID → alten behalten, neuen auflösen
        if new_p.security_id == PLACEHOLDER_SECURITY_ID && old_p.security_id != PLACEHOLDER_SECURITY_ID
          old_p, new_p = new_p, old_p
        end

        pairs << [old_p, new_p]
      end
    end

    pairs
  end

  # Spiele, in denen BEIDE IDs vorkommen → Konflikt, nicht automatisch mergebar.
  def games_with_both(id_a, id_b)
    (affected_games(id_a) & affected_games(id_b)).select do |game|
      in_game?(game, id_a) && in_game?(game, id_b)
    end
  end

  # Alle Spiele, die old_id in players, starting_players oder awards referenzieren.
  def affected_games(old_id)
    in_players = Game.where('players @> ?', { 'home'  => [{ 'player_id' => old_id }] }.to_json)
                     .or(Game.where('players @> ?', { 'guest' => [{ 'player_id' => old_id }] }.to_json))
    # jsonb_path_exists funktioniert korrekt mit nativen jsonb-Spalten und
    # findet Integer-Werte bei beliebiger Verschachtelung — unabhängig vom Speicherformat
    # (Normal-Hash oder Legacy-Array). Deckt beide Formate in starting_players und awards ab.
    path = '$.** ? (@ == $v)'
    in_sp_awards = Game.where(
      "jsonb_path_exists(starting_players, ?::jsonpath, jsonb_build_object('v', ?)) OR " \
      "jsonb_path_exists(awards, ?::jsonpath, jsonb_build_object('v', ?))",
      path, old_id, path, old_id
    )
    Game.where(id: in_players).or(Game.where(id: in_sp_awards))
  end

  # Mergt old_p in new_p und löscht old_p. Muss in einer Transaktion aufgerufen werden.
  def merge!(old_p, new_p)
    new_p.clubs    = merge_clubs(old_p.clubs, new_p.clubs)
    new_p.licenses = merge_licenses(old_p.licenses, new_p.licenses)
    new_p.save!(validate: false)

    Transfer.where(player_id: old_p.id).update_all(player_id: new_p.id)
    update_game_references(old_p.id, new_p.id)

    old_p.destroy!
  end

  def parse_date(str)
    return nil if str.blank?
    Date.parse(str.to_s[0, 10])
  rescue ArgumentError
    nil
  end

  def in_game?(game, pid)
    return true if game.players&.dig('home')&.any? { |p| p['player_id'] == pid }
    return true if game.players&.dig('guest')&.any? { |p| p['player_id'] == pid }

    %w[home guest].each do |side|
      sp = game.starting_players&.dig(side)
      if sp.is_a?(Hash)
        return true if sp.values.include?(pid)
      elsif sp.is_a?(Array)
        return true if sp.any? { |entry| entry['player_id'] == pid }
      end

      aw = game.awards&.dig(side)
      if aw.is_a?(Hash)
        return true if aw.values.include?(pid)
      elsif aw.is_a?(Array)
        return true if aw.any? { |entry| entry['player_id'] == pid }
      end
    end

    false
  end

  # Clubs: alle Einträge des neuen Spielers behalten; vom alten nur ergänzen,
  # was noch nicht durch denselben club_id + aktiven Zeitraum abgedeckt ist.
  def merge_clubs(old_clubs, new_clubs)
    old_clubs ||= []
    new_clubs ||= []

    new_active_club_ids = new_clubs
      .select { |c| c['valid_until'].nil? }
      .map { |c| c['club_id'] }
      .to_set

    additional = old_clubs.reject do |c|
      # Alten Eintrag weglassen, wenn neuer Spieler denselben Club aktiv hat
      c['valid_until'].nil? && new_active_club_ids.include?(c['club_id'])
    end

    (new_clubs + additional).sort_by { |c| c['created_at'].to_s }
  end

  # Lizenzen: bei gleichem team_id die History-Arrays zusammenführen;
  # sonst einfach anhängen.
  def merge_licenses(old_licenses, new_licenses)
    old_licenses ||= []
    new_licenses ||= []

    result = new_licenses.map(&:dup)

    old_licenses.each do |old_lic|
      existing = result.find { |l| l['team_id'].to_s == old_lic['team_id'].to_s }

      if existing
        combined = ((existing['history'] || []) + (old_lic['history'] || []))
          .uniq { |h| [h['created_at'].to_s, h['license_status_id'].to_s] }
          .sort_by { |h| h['created_at'].to_s }
        existing['history'] = combined
      else
        result << old_lic
      end
    end

    result
  end

  def update_game_references(old_id, new_id)
    affected_games(old_id).each do |game|
      changed = false

      if game.players.present?
        %w[home guest].each do |side|
          game.players[side]&.each do |p|
            next unless p['player_id'] == old_id

            p['player_id'] = new_id
            changed = true
          end
        end
      end

      if game.starting_players.present?
        %w[home guest].each do |side|
          sp = game.starting_players[side]
          next unless sp.present?

          if sp.is_a?(Hash)
            # Normalformat: {"goal" => 123, "defender1" => 456, ...}
            sp.transform_values! do |pid|
              if pid == old_id
                changed = true
                new_id
              else
                pid
              end
            end
          elsif sp.is_a?(Array)
            # Legacy-Format: [{"position" => "goal", "player_id" => 123, ...}, ...]
            sp.each do |entry|
              next unless entry['player_id'] == old_id

              entry['player_id'] = new_id
              changed = true
            end
          end
        end
      end

      if game.awards.present?
        %w[home guest].each do |side|
          aw = game.awards[side]
          next unless aw.present?

          if aw.is_a?(Hash)
            aw.transform_values! do |pid|
              if pid == old_id
                changed = true
                new_id
              else
                pid
              end
            end
          elsif aw.is_a?(Array)
            aw.each do |entry|
              next unless entry['player_id'] == old_id

              entry['player_id'] = new_id
              changed = true
            end
          end
        end
      end

      game.save!(validate: false) if changed
    end
  end
end
