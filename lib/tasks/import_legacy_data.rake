# frozen_string_literal: true

# lib/tasks/import_legacy_data.rake
#
# Imports clubs, players, and team-club assignments from the legacy API
# at api.saisonmanager.de into the local DB.
#
# Prerequisites: set LEGACY_USER and LEGACY_PASS env vars, or use defaults.
#
# Run:
#   bundle exec rails import:clubs     RAILS_ENV=production
#   bundle exec rails import:players   RAILS_ENV=production  [THREADS=20]
#   bundle exec rails import:team_clubs RAILS_ENV=production [THREADS=10]

namespace :import do
  LEGACY_BASE = 'https://saisonmanager.org'

  # ── Shared HTTP + session helper ─────────────────────────────────────────────
  def legacy_session
    require 'net/http'
    require 'json'

    user = ENV.fetch('LEGACY_USER', 'mguenther')
    pass = ENV.fetch('LEGACY_PASS', 'Guenni14-sbk')

    uri  = URI("#{LEGACY_BASE}/login")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = true
    http.open_timeout = 10
    http.read_timeout = 30

    req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = { username: user, password: pass }.to_json
    resp = http.request(req)

    cookie = resp['set-cookie']&.split(';')&.first
    abort 'ERROR: Login failed — check LEGACY_USER / LEGACY_PASS' unless cookie

    puts "  Logged in as #{user}"
    cookie
  end

  def legacy_fetch(path, cookie, retries: 3)
    uri  = URI("#{LEGACY_BASE}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = 30
    http.open_timeout = 10

    attempt = 0
    begin
      req = Net::HTTP::Get.new(uri.request_uri, 'Cookie' => cookie)
      resp = http.request(req)
      return nil unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    rescue StandardError => e
      attempt += 1
      if attempt < retries
        sleep(attempt * 0.5)
        retry
      end
      warn "  FAILED #{path}: #{e.message}"
      nil
    end
  end

  # ── import:clubs ─────────────────────────────────────────────────────────────
  desc 'Import clubs from legacy API (idempotent)'
  task clubs: :environment do
    puts "\n=== import:clubs ==="
    cookie = legacy_session
    conn   = ActiveRecord::Base.connection

    data = legacy_fetch('/api/v2/admin/clubs', cookie)
    abort 'ERROR: Could not fetch clubs' unless data.is_a?(Array)

    created = 0
    updated = 0

    data.each do |go|
      go_id = go['id']

      go['clubs'].each do |c|
        # Build game_operations_hash: home GO + additional GOs
        goh = [{ 'game_operation_id' => go_id, 'home_game_operation' => true }]
        (c['additional_game_operation_ids'] || []).each do |aid|
          goh << { 'game_operation_id' => aid, 'home_game_operation' => false }
        end

        existing = Club.find_by(id: c['id'])

        if existing
          existing.update!(
            name:                 c['name'],
            long_name:            c['long_name'].presence,
            short_name:           c['short_name'].presence,
            state:                c['state'].presence,
            game_operations_hash: goh
          )
          updated += 1
        else
          conn.execute(<<~SQL)
            INSERT INTO clubs (id, name, long_name, short_name, state, game_operations_hash, created_at, updated_at)
            VALUES (
              #{conn.quote(c['id'])},
              #{conn.quote(c['name'])},
              #{conn.quote(c['long_name'].presence)},
              #{conn.quote(c['short_name'].presence)},
              #{conn.quote(c['state'].presence)},
              #{conn.quote(goh.to_json)},
              NOW(), NOW()
            )
            ON CONFLICT (id) DO UPDATE SET
              name                 = EXCLUDED.name,
              long_name            = EXCLUDED.long_name,
              short_name           = EXCLUDED.short_name,
              state                = EXCLUDED.state,
              game_operations_hash = EXCLUDED.game_operations_hash,
              updated_at           = NOW()
          SQL
          created += 1
        end
      end
    end

    conn.reset_pk_sequence!('clubs')

    puts "  Done: #{created} inserted, #{updated} updated"
    puts "  Total clubs: #{Club.count}"
  end

  # ── import:players ────────────────────────────────────────────────────────────
  desc 'Import players (with clubs + licenses JSONB) from legacy API (idempotent)'
  task players: :environment do
    require 'net/http'
    require 'json'

    threads_count = (ENV['THREADS'] || 20).to_i
    puts "\n=== import:players (#{threads_count} threads) ==="

    cookie = legacy_session

    # Step 1 — collect all player IDs
    puts '  Fetching player list...'
    all_players = legacy_fetch('/players.json', cookie)
    abort 'ERROR: Could not fetch player list' unless all_players.is_a?(Array)

    ids = all_players.map { |p| p['id'] }.compact.uniq
    puts "  #{ids.size} players to import"

    # Step 2 — fetch full detail per player in parallel
    conn        = ActiveRecord::Base.connection
    queue       = Queue.new
    ids.each { |id| queue << id }
    threads_count.times { queue << nil }

    ok_count     = 0
    skip_count   = 0
    fail_count   = 0
    db_mutex     = Mutex.new
    counter_mutex = Mutex.new
    total        = ids.size

    threads = threads_count.times.map do
      Thread.new do
        # Each thread gets its own HTTP session via the shared cookie
        while (player_id = queue.pop)
          detail = legacy_fetch("/api/v2/admin/players/#{player_id}", cookie)

          unless detail.is_a?(Hash)
            counter_mutex.synchronize { fail_count += 1 }
            next
          end

          clubs    = (detail['clubs']    || []).to_json
          licenses = (detail['licenses'] || []).to_json

          gender = detail['gender'] || (detail['male'] ? 'M' : 'W')

          db_mutex.synchronize do
            conn.execute(<<~SQL)
              INSERT INTO players (
                id, last_name, first_name, birthdate, gender, male,
                nation_id, clubs, licenses,
                security_id, created_at, updated_at
              ) VALUES (
                #{conn.quote(detail['id'])},
                #{conn.quote(detail['last_name'].to_s)},
                #{conn.quote(detail['first_name'].to_s)},
                #{conn.quote(detail['birthdate'])},
                #{conn.quote(gender)},
                #{gender == 'M'},
                #{conn.quote(detail['nation_id']&.to_s)},
                #{conn.quote(clubs)}::jsonb,
                #{conn.quote(licenses)}::jsonb,
                #{conn.quote(detail['security_id'])},
                NOW(), NOW()
              )
              ON CONFLICT (id) DO UPDATE SET
                last_name   = EXCLUDED.last_name,
                first_name  = EXCLUDED.first_name,
                birthdate   = EXCLUDED.birthdate,
                gender      = EXCLUDED.gender,
                male        = EXCLUDED.male,
                nation_id   = EXCLUDED.nation_id,
                clubs       = EXCLUDED.clubs,
                licenses    = EXCLUDED.licenses,
                security_id = EXCLUDED.security_id,
                updated_at  = NOW()
            SQL
            ok_count += 1
          end

          counter_mutex.synchronize do
            done = ok_count + fail_count
            if done % 1000 == 0
              pct = (done * 100.0 / total).round(1)
              puts "  #{done}/#{total} (#{pct}%) – #{ok_count} ok, #{fail_count} failed"
            end
          end
        end
      end
    end

    threads.each(&:join)
    conn.reset_pk_sequence!('players')

    puts "  Done: #{ok_count} ok, #{fail_count} failed"
    puts "  Total players in DB: #{Player.count}"
  end

  # ── import:team_clubs ─────────────────────────────────────────────────────────
  desc 'Backfill club_id on teams from legacy API (idempotent)'
  task team_clubs: :environment do
    require 'net/http'
    require 'json'

    threads_count = (ENV['THREADS'] || 10).to_i
    puts "\n=== import:team_clubs (#{threads_count} threads) ==="

    cookie = legacy_session
    conn   = ActiveRecord::Base.connection

    team_ids = Team.where(club_id: nil).pluck(:id)
    puts "  #{team_ids.size} teams without club_id"

    if team_ids.empty?
      puts '  Nothing to do.'
      next
    end

    queue         = Queue.new
    team_ids.each { |id| queue << id }
    threads_count.times { queue << nil }

    updated_count = 0
    not_found     = 0
    no_club       = 0
    db_mutex      = Mutex.new
    counter_mutex = Mutex.new
    total         = team_ids.size

    threads = threads_count.times.map do
      Thread.new do
        while (team_id = queue.pop)
          detail = legacy_fetch("/api/v2/admin/teams/#{team_id}", cookie)

          unless detail.is_a?(Hash)
            counter_mutex.synchronize { not_found += 1 }
            next
          end

          club_id = detail['club_id']

          unless club_id
            counter_mutex.synchronize { no_club += 1 }
            next
          end

          db_mutex.synchronize do
            conn.execute("UPDATE teams SET club_id = #{conn.quote(club_id)}, updated_at = NOW() WHERE id = #{conn.quote(team_id)}")
            updated_count += 1

            done = updated_count + not_found + no_club
            if done % 500 == 0
              pct = (done * 100.0 / total).round(1)
              puts "  #{done}/#{total} (#{pct}%) – #{updated_count} updated, #{not_found} not found, #{no_club} no club"
            end
          end
        end
      end
    end

    threads.each(&:join)

    puts "  Done: #{updated_count} teams assigned, #{not_found} not found in legacy API, #{no_club} had no club"
    puts "  Teams with club_id: #{Team.where.not(club_id: nil).count}/#{Team.count}"
  end
end
