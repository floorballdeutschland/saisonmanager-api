namespace :games do
  desc "Fix imported lineups: rename legacy player-name keys (last_name/first_name -> player_name/player_firstname)"
  task fix_imported_player_names: :environment do
    # Der Altdaten-Import schrieb Spielernamen unter last_name/first_name, während
    # Lesepfad und Frontend player_name/player_firstname erwarten (wie im
    # Live-Erfassungspfad GamesController#add_player_to_lineup). Dadurch blieben
    # Namen importierter Spiele leer. Dieser Task schlüsselt die Keys in
    # Game#players um. Idempotent: bereits korrekte Einträge werden übersprungen.
    scope = Game.where("players::text LIKE ?", '%"last_name"%')
                .or(Game.where("players::text LIKE ?", '%"first_name"%'))
    total = scope.count
    puts "#{total} Spiele mit Alt-Keys in players zu prüfen."

    fixed = 0
    skipped = 0
    errors = 0

    scope.find_each(batch_size: 100) do |game|
      players = game.players
      next if players.blank?

      game_changed = false

      %w[home guest].each do |team|
        lineup = players[team]
        next unless lineup.is_a?(Array)

        lineup.each do |player|
          next unless player.is_a?(Hash)
          next unless player.key?('last_name') || player.key?('first_name')

          last_name = player.delete('last_name')
          first_name = player.delete('first_name')
          player['player_name'] = last_name if player['player_name'].blank? && last_name.present?
          player['player_firstname'] = first_name if player['player_firstname'].blank? && first_name.present?
          game_changed = true
        end
      end

      unless game_changed
        skipped += 1
        next
      end

      begin
        game.update_column(:players, players)
        fixed += 1
        print "." if (fixed % 500).zero?
      rescue StandardError => e
        errors += 1
        puts "\n  ERROR game #{game.id}: #{e.message}"
      end
    end

    puts "\nFertig. Korrigiert: #{fixed}, Übersprungen: #{skipped}, Fehler: #{errors}"
  end
end
