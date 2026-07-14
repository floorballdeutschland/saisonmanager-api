# frozen_string_literal: true

# lib/tasks/import_prod_data.rake
#
# Imports all publicly accessible data from saisonmanager.de into the local DB.
# Run with:
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
#     bundle exec rails import:prod RAILS_ENV=development
#
# Options via ENV:
#   THREADS=N         parallel threads for game detail fetching (default: 8)
#   ONLY_SEASON=N     import only leagues for a specific season ID

namespace :import do
  desc 'Import all public data from saisonmanager.de'
  task prod: :environment do
    require 'net/http'
    require 'json'
    require 'set'

    BASE_URL    = 'https://saisonmanager.de/api/v2'
    THREADS     = (ENV['THREADS'] || 8).to_i
    ONLY_SEASON = ENV['ONLY_SEASON']&.to_i

    # ── HTTP helper ──────────────────────────────────────────────────────────
    fetch = lambda do |path|
      attempts = 0
      begin
        uri  = URI("#{BASE_URL}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl      = true
        http.read_timeout = 30
        http.open_timeout = 10
        resp = http.get(uri.request_uri)
        return nil unless resp.is_a?(Net::HTTPSuccess)

        JSON.parse(resp.body)
      rescue StandardError => e
        attempts += 1
        if attempts < 3
          sleep(attempts * 0.5)
          retry
        end
        warn "  FAILED #{path}: #{e.message}"
        nil
      end
    end

    now = Time.current

    # ── 1. Reset tables ──────────────────────────────────────────────────────
    puts "\n=== Resetting database ==="
    conn = ActiveRecord::Base.connection
    conn.execute(<<~SQL)
      TRUNCATE games, game_days, leagues, teams, arenas, game_operations, settings
      RESTART IDENTITY CASCADE
    SQL
    puts '  Done.'

    # ── 2. Settings + game_operations from /init ─────────────────────────────
    puts "\n=== Fetching /init ==="
    init = fetch.call('/init')
    abort 'ERROR: Could not fetch /init' unless init.is_a?(Hash)

    seasons_array   = init['seasons']     # [{id, name, current}, ...]
    current_season  = init['current_season_id']
    game_ops_data   = init['game_operations']

    seasons_hash = seasons_array.each_with_object({}) do |s, h|
      h[s['id'].to_s] = { 'name' => s['name'], 'current' => s['current'] == true }
    end

    Setting.create!(
      seasons: seasons_hash,
      systems: { '1' => { 'current_season_id' => current_season } },
      nations: {
        '1' => { 'name' => 'Deutschland' }, '2' => { 'name' => 'Österreich' },
        '3' => { 'name' => 'Schweiz' },     '4' => { 'name' => 'Dänemark' },
        '5' => { 'name' => 'Schweden' },    '6' => { 'name' => 'Finnland' },
        '7' => { 'name' => 'Tschechien' },  '99' => { 'name' => 'Sonstige' }
      },
      league_categories: {
        '1' => { 'name' => 'Großfeld' }, '2' => { 'name' => 'Kleinfeld' },
        '3' => { 'name' => 'Halbfeld' }, '4' => { 'name' => 'Pokal Großfeld' },
        '100' => { 'name' => 'Sonstige' }, '102' => { 'name' => 'Großfeld DM' }
      },
      league_classes: {
        '1'  => { 'name' => '1. Bundesliga' }, '2' => { 'name' => '2. Bundesliga' },
        '3'  => { 'name' => 'Regionalliga' },  '4' => { 'name' => 'Oberliga' },
        '5'  => { 'name' => 'Verbandsliga' },  '6' => { 'name' => 'Landesliga' },
        '7'  => { 'name' => 'Bezirksliga' },   '8' => { 'name' => 'Kreisliga' },
        '9'  => { 'name' => 'Sonstige' },      '10' => { 'name' => 'Bundesliga' }
      },
      league_systems: {
        '1' => { 'name' => 'Einfachrunde' }, '2' => { 'name' => 'Doppelrunde' },
        '3' => { 'name' => 'Dreifachrunde' }, '4' => { 'name' => 'Standard' }
      },
      user_groups: {
        '1' => { 'name' => 'Admin' },   '2' => { 'name' => 'SBK' },
        '3' => { 'name' => 'RSK' },     '4' => { 'name' => 'VM' },
        '5' => { 'name' => 'TM' }
      },
      penalties: {
        '1' => { 'name' => '2 Minuten' },            '2' => { 'name' => '5 Minuten' },
        '3' => { 'name' => '10 Minuten' },            '4' => { 'name' => '20 Minuten (Spieldauer)' },
        '5' => { 'name' => 'Spielausschluss' }
      },
      penalty_codes: {
        '1' => { 'name' => 'Behinderung' },          '2' => { 'name' => 'Stockschlag' },
        '3' => { 'name' => 'Haken' },                '4' => { 'name' => 'Halten' },
        '5' => { 'name' => 'Hoher Stock' },          '6' => { 'name' => 'Unsportliches Verhalten' }
      },
      point_corrections: {},
      liveticker: {}
    )
    puts "  Setting created (current season: #{current_season})"

    game_ops_data.each do |op|
      conn.execute(<<~SQL)
        INSERT INTO game_operations (id, name, short_name, path, logo_url, logo_quad_url, created_at, updated_at)
        VALUES (
          #{conn.quote(op['id'])},
          #{conn.quote(op['name'])},
          #{conn.quote(op['short_name'])},
          #{conn.quote(op['path'])},
          #{conn.quote(op['logo_url'])},
          #{conn.quote(op['logo_quad_url'])},
          NOW(), NOW()
        )
        ON CONFLICT (id) DO NOTHING
      SQL
    end
    puts "  #{game_ops_data.size} game operations"

    # ── 3. Leagues (all game_ops × all seasons) ───────────────────────────────
    puts "\n=== Importing leagues ==="
    season_ids     = ONLY_SEASON ? [ONLY_SEASON] : seasons_array.map { |s| s['id'] }
    all_league_ids = []

    game_ops_data.each do |op|
      season_ids.each do |season_id|
        leagues = fetch.call("/game_operations/#{op['id']}/leagues/#{season_id}")
        next unless leagues.is_a?(Array) && leagues.any?

        # date_q: only quote if the value is a non-empty string, else NULL
        date_q = ->(v) { v.is_a?(String) && !v.empty? ? conn.quote(v) : 'NULL' }

        leagues.each do |l|
          conn.execute(<<~SQL)
            INSERT INTO leagues (
              id, game_operation_id, name, short_name, season_id,
              league_class_id, league_category_id, league_system_id, league_type,
              female, enable_scorer, field_size, league_modus, has_preround,
              table_modus, periods, period_length, overtime_length,
              order_key, deadline, before_deadline, legacy_league,
              created_at, updated_at
            ) VALUES (
              #{conn.quote(l['id'])},
              #{conn.quote(l['game_operation_id'])},
              #{conn.quote(l['name'])},
              #{conn.quote(l['short_name'] || l['name'])},
              #{conn.quote(l['season_id'])},
              #{conn.quote(l['league_class_id'])},
              #{conn.quote(l['league_category_id'])},
              #{conn.quote(l['league_system_id'])},
              #{conn.quote(l['league_type'])},
              #{l['female'] == true},
              #{l['enable_scorer'] == true},
              #{conn.quote(l['field_size'])},
              #{conn.quote(l['league_modus'])},
              #{l['has_preround'] == true},
              #{conn.quote(l['table_modus'])},
              #{conn.quote(l['periods'])},
              #{conn.quote(l['period_length'])},
              #{conn.quote(l['overtime_length'])},
              #{conn.quote(l['order_key'])},
              #{date_q.call(l['deadline'])},
              #{date_q.call(l['before_deadline'])},
              #{l['legacy_league'] == true},
              NOW(), NOW()
            )
            ON CONFLICT (id) DO NOTHING
          SQL
          all_league_ids << l['id']
        end

        sleep 0.05
      end
    end

    all_league_ids.uniq!
    puts "  #{all_league_ids.size} leagues"

    # ── 4. Schedules → arenas, game_days, game metadata ─────────────────────
    puts "\n=== Importing schedules ==="

    game_day_id_to_league = {}   # game_day_id => league_id
    game_id_to_meta       = {}   # game_id => { game_day_id:, schedule_entry: sg }
    seen_arenas           = Set.new
    seen_game_days        = Set.new
    total_schedule        = 0

    all_league_ids.each_with_index do |league_id, idx|
      schedule = fetch.call("/leagues/#{league_id}/schedule")
      unless schedule.is_a?(Array) && schedule.any?
        print '.'
        next
      end

      total_schedule += schedule.size

      schedule.each do |sg|
        game_id     = sg['game_id']
        game_day_id = sg['game_day_id']
        arena_id    = sg['arena']

        # Upsert arena
        if arena_id && !seen_arenas.include?(arena_id)
          conn.execute(<<~SQL)
            INSERT INTO arenas (id, name, address, schedule_item, active, disabled, created_at, updated_at)
            VALUES (
              #{conn.quote(arena_id)},
              #{conn.quote(sg['arena_name'])},
              #{conn.quote(sg['arena_address'])},
              #{conn.quote(sg['arena_short'])},
              true, false, NOW(), NOW()
            )
            ON CONFLICT (id) DO NOTHING
          SQL
          seen_arenas << arena_id
        end

        # Upsert game_day
        if game_day_id && !seen_game_days.include?(game_day_id)
          conn.execute(<<~SQL)
            INSERT INTO game_days (id, league_id, arena_id, number, date, created_at, updated_at)
            VALUES (
              #{conn.quote(game_day_id)},
              #{conn.quote(league_id)},
              #{conn.quote(arena_id)},
              #{conn.quote(sg['game_day'])},
              #{conn.quote(sg['date'])},
              NOW(), NOW()
            )
            ON CONFLICT (id) DO NOTHING
          SQL
          seen_game_days   << game_day_id
          game_day_id_to_league[game_day_id] = league_id
        end

        game_id_to_meta[game_id] = {
          game_day_id:,
          nominated_referee_string: sg['nominated_referee_string'],
          notice_type:              sg['notice_type'],
          notice_string:            sg['notice_string'],
          group_identifier:         sg['group_identifier'],
          series_title:             sg['series_title'],
          series_number:            sg['series_number'],
          home_team_filling_rule:   sg['home_team_filling_rule'],
          home_team_filling_param:  sg['home_team_filling_parameter'],
          guest_team_filling_rule:  sg['guest_team_filling_rule'],
          guest_team_filling_param: sg['guest_team_filling_parameter'],
          start_time:               sg['time'],
          started:                  sg['started'] || sg['state'] == 'ended',
          ended:                    sg['ended']   || sg['state'] == 'ended',
        }
      end

      if (idx + 1) % 50 == 0
        puts "  #{idx + 1}/#{all_league_ids.size} leagues processed (#{total_schedule} games so far)"
      else
        print '.'
      end

      sleep 0.05
    end

    puts "\n  #{seen_arenas.size} arenas, #{seen_game_days.size} game days, #{game_id_to_meta.size} games"

    # ── 5. Game details (parallel) ────────────────────────────────────────────
    puts "\n=== Fetching game details (#{THREADS} threads) ==="

    game_ids       = game_id_to_meta.keys
    team_map       = {}          # team_id => team_name
    games_ok       = 0
    games_failed   = 0
    team_mutex     = Mutex.new
    db_mutex       = Mutex.new
    counter_mutex  = Mutex.new

    queue = Queue.new
    game_ids.each { |id| queue << id }
    THREADS.times  { queue << nil }   # sentinel per thread

    total = game_ids.size
    puts "  Total: #{total} games"

    threads = THREADS.times.map do
      Thread.new do
        while (game_id = queue.pop)
          game = fetch.call("/games/#{game_id}")

          unless game.is_a?(Hash)
            counter_mutex.synchronize { games_failed += 1 }
            next
          end

          meta   = game_id_to_meta[game_id]
          result = game['result'] || {}

          # Track team names
          [[game['home_team_id'], game['home_team_name']],
           [game['guest_team_id'], game['guest_team_name']]].each do |tid, tname|
            next unless tid

            team_mutex.synchronize { team_map[tid] ||= tname }
          end

          db_mutex.synchronize do
            conn.execute(<<~SQL)
              INSERT INTO games (
                id, game_day_id, home_team_id, guest_team_id,
                game_number, start_time, actual_start_time,
                game_status, ingame_status, audience,
                forfait, overtime, started, ended, game_ended,
                live_stream_link, vod_link,
                notice_type, notice_string, nominated_referee_string,
                group_identifier, series_title, series_number,
                home_team_filling_rule, home_team_filling_parameter,
                guest_team_filling_rule, guest_team_filling_parameter,
                events, players, starting_players, awards,
                created_at, updated_at
              ) VALUES (
                #{conn.quote(game['id'])},
                #{conn.quote(meta[:game_day_id])},
                #{conn.quote(game['home_team_id'])},
                #{conn.quote(game['guest_team_id'])},
                #{conn.quote(game['game_number'].to_s)},
                #{conn.quote(meta[:start_time])},
                #{conn.quote(game['actual_start_time'])},
                #{conn.quote(game['game_status'])},
                #{conn.quote(game['ingame_status'])},
                #{conn.quote(game['audience'])},
                #{result['forfait'] ? 1 : 0},
                #{result['overtime'] == true},
                #{meta[:started] == true},
                #{meta[:ended] == true},
                #{meta[:ended] == true},
                #{conn.quote(game['live_stream_link'])},
                #{conn.quote(game['vod_link'])},
                #{conn.quote(meta[:notice_type])},
                #{conn.quote(meta[:notice_string])},
                #{conn.quote(meta[:nominated_referee_string])},
                #{conn.quote(meta[:group_identifier])},
                #{conn.quote(meta[:series_title])},
                #{conn.quote(meta[:series_number])},
                #{conn.quote(meta[:home_team_filling_rule])},
                #{conn.quote(meta[:home_team_filling_param])},
                #{conn.quote(meta[:guest_team_filling_rule])},
                #{conn.quote(meta[:guest_team_filling_param])},
                #{conn.quote((game['events'] || []).to_json)},
                #{conn.quote((game['players'] || {}).to_json)},
                #{conn.quote((game['starting_players'] || {}).to_json)},
                #{conn.quote((game['awards'] || {}).to_json)},
                NOW(), NOW()
              )
              ON CONFLICT (id) DO NOTHING
            SQL
            games_ok += 1
          end

          if (games_ok + games_failed) % 500 == 0
            pct = ((games_ok + games_failed) * 100.0 / total).round(1)
            puts "  #{games_ok + games_failed}/#{total} (#{pct}%) – #{games_ok} ok, #{games_failed} failed"
          end
        end
      end
    end

    threads.each(&:join)
    puts "  Games imported: #{games_ok} ok, #{games_failed} failed"

    # ── 6. Team stubs ─────────────────────────────────────────────────────────
    puts "\n=== Creating team stubs ==="
    team_map.each do |team_id, team_name|
      conn.execute(<<~SQL)
        INSERT INTO teams (id, name, short_name, approved, syndicate, syndicate_clubs, cup_leagues, created_at, updated_at)
        VALUES (
          #{conn.quote(team_id)},
          #{conn.quote(team_name)},
          #{conn.quote(team_name)},
          true, false, '{}', '{}',
          NOW(), NOW()
        )
        ON CONFLICT (id) DO NOTHING
      SQL
    end
    puts "  #{team_map.size} teams"

    # ── 7. Reset sequences ────────────────────────────────────────────────────
    puts "\n=== Resetting sequences ==="
    %w[settings game_operations leagues arenas game_days games teams].each do |tbl|
      conn.reset_pk_sequence!(tbl)
    end
    puts '  Done.'

    # ── Summary ───────────────────────────────────────────────────────────────
    puts "\n=== Import complete ==="
    puts "  Game Operations : #{GameOperation.count}"
    puts "  Leagues         : #{League.count}"
    puts "  Arenas          : #{Arena.count}"
    puts "  Game Days       : #{GameDay.count}"
    puts "  Games           : #{Game.count}"
    puts "  Teams           : #{Team.count}"
    puts "  Current season  : #{current_season}"
  end
end
