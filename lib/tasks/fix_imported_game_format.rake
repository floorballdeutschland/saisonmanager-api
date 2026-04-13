namespace :games do
  desc "Fix imported game data: convert events and starting_players from API format to internal format"
  task fix_imported_format: :environment do
    PENALTY_TYPE_TO_ID = {
      'penalty_2'       => 1,
      'penalty_2and2'   => 2,
      'penalty_5'       => 3,
      'penalty_10'      => 4,
      'penalty_ms_tech' => 5,
      'penalty_ms_full' => 6,
      'penalty_ms1'     => 7,
      'penalty_ms2'     => 8,
      'penalty_ms3'     => 9
    }.freeze

    # Step 1: Update Setting.current.penalties to include 'mapping' field
    puts "Step 1: Updating Setting.current.penalties with mapping fields..."
    setting = Setting.current
    new_penalties = {
      '1' => { 'name' => '2 Minuten',               'mapping' => 'penalty_2' },
      '2' => { 'name' => '2+2 Minuten',             'mapping' => 'penalty_2and2' },
      '3' => { 'name' => '5 Minuten',               'mapping' => 'penalty_5' },
      '4' => { 'name' => '10 Minuten',              'mapping' => 'penalty_10' },
      '5' => { 'name' => 'Spieldauerstrafe (tech.)', 'mapping' => 'penalty_ms_tech' },
      '6' => { 'name' => 'Spielstrafe',             'mapping' => 'penalty_ms_full' },
      '7' => { 'name' => 'Spielstrafe 1',           'mapping' => 'penalty_ms1' },
      '8' => { 'name' => 'Spielstrafe 2',           'mapping' => 'penalty_ms2' },
      '9' => { 'name' => 'Spielstrafe 3',           'mapping' => 'penalty_ms3' }
    }
    setting.update_column(:penalties, new_penalties)
    puts "  Done."

    # Step 2: Fix events format
    # API format uses: number, assist, event_team, event_id, penalty_type, penalty_reason
    # Internal format uses: home_number/guest_number, home_assist/guest_assist, id, penalty_id, penalty_code_id
    # Detection: API format has 'number' key but no 'home_number'/'guest_number'
    puts "Step 2: Converting events from API format to internal format..."
    events_scope = Game.where.not(events: nil).where("events != '[]'::jsonb")
    total = events_scope.count
    puts "  #{total} games with events to process."

    fixed = 0
    skipped = 0
    errors = 0

    events_scope.find_each(batch_size: 100) do |game|
      events = game.events
      next if events.blank?

      # Skip if already in internal format (first event has home_number or guest_number)
      sample = events.find { |e| e['event_type'].present? || e['number'].present? }
      next if sample.nil?
      next if sample['home_number'].present? || sample['guest_number'].present?
      next unless sample['number'].present?

      begin
        new_events = events.map do |event|
          team = event['event_team']
          number = event['number']
          assist = event['assist']

          e = {
            'id'          => event['event_id'],
            'period'      => event['period'],
            'time'        => event['time'],
            'home_goals'  => event['home_goals'],
            'guest_goals' => event['guest_goals'],
            'event_team'  => team
          }

          if team == 'home'
            e['home_number'] = number
            e['home_assist'] = assist if assist.present?
          elsif team == 'guest'
            e['guest_number'] = number
            e['guest_assist'] = assist if assist.present?
          end

          if event['event_type'] == 'penalty'
            e['penalty_id']      = PENALTY_TYPE_TO_ID[event['penalty_type']]
            e['penalty_code_id'] = event['penalty_reason']
          end

          e
        end

        game.update_column(:events, new_events)
        fixed += 1
        print "." if fixed % 500 == 0
      rescue => ex
        errors += 1
        puts "\n  ERROR game #{game.id}: #{ex.message}"
      end
    end

    puts "\n  Fixed: #{fixed}, Skipped: #{skipped}, Errors: #{errors}"

    # Step 3: Fix starting_players format
    # API format: {"home": [{"position": "goal", "player_id": 29298, ...}], "guest": [...]}
    # Internal format: {"home": {"goal": 29298, ...}, "guest": {...}}
    puts "Step 3: Converting starting_players from array to hash format..."
    sp_scope = Game.where.not(starting_players: nil).where("starting_players != '{}'::jsonb")
    total_sp = sp_scope.count
    puts "  #{total_sp} games with starting_players to process."

    fixed_sp = 0
    skipped_sp = 0
    errors_sp = 0

    sp_scope.find_each(batch_size: 100) do |game|
      sp = game.starting_players
      next if sp.blank?

      # Skip if already in hash format (home value is a Hash, not Array)
      sample = sp['home'] || sp['guest']
      next if sample.nil?
      if sample.is_a?(Hash)
        skipped_sp += 1
        next
      end
      next unless sample.is_a?(Array)

      begin
        new_sp = {}
        %w[home guest].each do |team|
          arr = sp[team]
          next unless arr.is_a?(Array) && arr.present?
          new_sp[team] = arr.each_with_object({}) do |player, h|
            pos = player['position']
            pid = player['player_id']
            h[pos] = pid if pos.present? && pid.present?
          end
        end

        game.update_column(:starting_players, new_sp)
        fixed_sp += 1
        print "." if fixed_sp % 500 == 0
      rescue => ex
        errors_sp += 1
        puts "\n  ERROR game #{game.id}: #{ex.message}"
      end
    end

    puts "\n  Fixed: #{fixed_sp}, Skipped (already hash): #{skipped_sp}, Errors: #{errors_sp}"

    # Step 4: Fix awards format
    # API format: {"home": [{"award": "mvp", "player_id": 29298, ...}], "guest": [...]}
    # Internal format: {"home": {"mvp": 29298}, "guest": {"mvp": nil}}
    puts "Step 4: Converting awards from array to hash format..."
    awards_scope = Game.where.not(awards: nil).where("awards != '{}'::jsonb")
    total_aw = awards_scope.count
    puts "  #{total_aw} games with awards to process."

    fixed_aw = 0
    skipped_aw = 0
    errors_aw = 0

    awards_scope.find_each(batch_size: 100) do |game|
      aw = game.awards
      next if aw.blank?

      sample = aw['home'] || aw['guest']
      next if sample.nil?
      if sample.is_a?(Hash)
        skipped_aw += 1
        next
      end
      next unless sample.is_a?(Array)

      begin
        new_aw = {}
        %w[home guest].each do |team|
          arr = aw[team]
          next unless arr.is_a?(Array) && arr.present?
          new_aw[team] = arr.each_with_object({}) do |entry, h|
            award_key = entry['award']
            player_id = entry['player_id']
            h[award_key] = player_id.present? ? player_id : nil if award_key.present?
          end
        end

        game.update_column(:awards, new_aw)
        fixed_aw += 1
        print "." if fixed_aw % 500 == 0
      rescue => ex
        errors_aw += 1
        puts "\n  ERROR game #{game.id}: #{ex.message}"
      end
    end

    puts "\n  Fixed: #{fixed_aw}, Skipped (already hash): #{skipped_aw}, Errors: #{errors_aw}"

    puts "\nDone. Run a quick sanity check:"
    puts "  rails runner 'g = Game.find(45900); puts g.starting_players_with_numbers.keys.inspect; puts g.evaluate_scorer.values.first(3).map { |s| [s[:goals], s[:assists]] }.inspect'"
  end
end
