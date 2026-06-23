# frozen_string_literal: true

# lib/tasks/import_old_seasons.rake
#
# PoC: Rekonstruktion der Alt-Saisons 2010/11–2013/14 aus den MariaDB-Dumps des
# Vorgängersystems (Tabellen-Präfix `<verband>_<saison>_*`, siehe
# produktivdaten/MAPPING_KONZEPT_altdaten_2010-2014.md).
#
# Scope dieses PoC: EINE Liga eines Verbands einer Saison. Default ist ein
# DRY-RUN (liest, transformiert, reportet – schreibt NICHT). Mit WRITE=1 werden
# Liga/Teams/Spieltage/Spiele idempotent angelegt.
#
# Zwei Datenquellen:
#   legacy:league      – direkt aus einer MariaDB (benötigt Gem mysql2)
#   legacy:league_json – aus einem JSON-Bundle (kein Gem, keine Dockerfile-
#                        Änderung; per export_liga.sql + JSON_OBJECT erzeugt)
#
# Beispiele:
#   LEGACY_MYSQL_URL="mysql2://root:pw@127.0.0.1:3307/saison201314" \
#     bundle exec rails "legacy:league" VERBAND=fvd SEASON=2013_2014 LIGA=33
#   bundle exec rails "legacy:league_json" BUNDLE=/tmp/liga33_bundle.json
#   bundle exec rails "legacy:league_json" BUNDLE=/tmp/liga33_bundle.json WRITE=1 GO_ID=1

namespace :legacy do
  desc 'PoC: eine Alt-Liga aus MariaDB importieren (Dry-Run; WRITE=1 schreibt)'
  task league: :environment do
    verband = ENV.fetch('VERBAND')
    season  = ENV.fetch('SEASON')
    liga_id = ENV.fetch('LIGA').to_i
    client  = legacy_mysql_client
    prefix  = "#{verband}_#{season}"

    liga = query_one(client, "SELECT * FROM `#{prefix}_liga` WHERE id_liga = #{liga_id}")
    abort "Liga #{liga_id} in #{prefix} nicht gefunden" unless liga
    liga['klasse_name'] = query_one(client, "SELECT name FROM global_klasse WHERE id_klasse = #{liga['id_klasse'].to_i}")&.fetch('name', nil)

    mannschaften = query_all(client, "SELECT * FROM `#{prefix}_mannschaft` WHERE id_liga = #{liga_id}")
    spieltage    = query_all(client, "SELECT * FROM `#{prefix}_spieltag` WHERE id_liga = #{liga_id}")
    st_ids       = spieltage.map { |s| s['id_spieltag'].to_i }
    begegnungen  = st_ids.empty? ? [] : query_all(client, "SELECT * FROM `#{prefix}_begegnung` WHERE id_spieltag IN (#{st_ids.join(',')})")
    beg_ids      = begegnungen.map { |b| b['id_begegnung'].to_i }
    ereignisse   = beg_ids.empty? ? [] : query_all(client, "SELECT * FROM `#{prefix}_ereignis` WHERE id_begegnung IN (#{beg_ids.join(',')})")
    mitspieler   = beg_ids.empty? ? [] : query_all(client, "SELECT * FROM `#{prefix}_mitspieler` WHERE id_begegnung IN (#{beg_ids.join(',')})")

    process_league(
      label: "#{prefix} ##{liga_id}",
      liga:, mannschaften:, spieltage:, begegnungen:,
      ev_by_beg: ereignisse.group_by { |e| e['id_begegnung'].to_i },
      ms_by_beg: mitspieler.group_by { |m| m['id_begegnung'].to_i },
      verein_names: name_map(client, 'global_verein', 'id_verein', 'name'),
      spielort_names: name_map(client, 'global_spielort', 'id_spielort', 'name')
    )
  end

  desc 'PoC: eine Alt-Liga aus einem JSON-Bundle importieren (Dry-Run; WRITE=1 schreibt)'
  task league_json: :environment do
    require 'json'
    bundle = JSON.parse(File.read(ENV.fetch('BUNDLE')))

    process_league(
      label: "#{bundle['verband']}_#{bundle['season']} ##{bundle['liga_id']}",
      liga: bundle['liga'],
      mannschaften: bundle['mannschaft'],
      spieltage: bundle['spieltag'],
      begegnungen: bundle['begegnung'],
      ev_by_beg: (bundle['ereignis'] || []).group_by { |e| e['id_begegnung'].to_i },
      ms_by_beg: (bundle['mitspieler'] || []).group_by { |m| m['id_begegnung'].to_i },
      verein_names: (bundle['verein_names'] || {}).transform_keys(&:to_i),
      spielort_names: (bundle['spielort_names'] || {}).transform_keys(&:to_i)
    )
  end

  # ── gemeinsame Orchestrierung (quellenunabhängig) ─────────────────────────────
  def process_league(label:, liga:, mannschaften:, spieltage:, begegnungen:, ev_by_beg:, ms_by_beg:, verein_names:, spielort_names:)
    write = ENV['WRITE'] == '1'
    go_id = ENV['GO_ID']&.to_i
    abort 'WRITE=1 benötigt GO_ID=<game_operation_id>' if write && go_id.nil?

    league_attrs = LegacyImport::Transformer.league_attrs(liga, game_operation_id: go_id || 0)

    puts "\n=== Liga #{label} ==="
    puts "  #{liga['name']} (#{liga['kurzname']}) – Saison #{league_attrs[:season_id]}"
    puts "  → league_attrs: #{league_attrs.except(:game_operation_id).to_json}"
    puts "  Teams: #{mannschaften.size}, Spieltage: #{spieltage.size}, Spiele: #{begegnungen.size}"
    warn_unmapped(league_attrs, liga)
    report_sample(begegnungen, ev_by_beg, ms_by_beg)

    unless write
      puts "\n(DRY-RUN – nichts geschrieben. WRITE=1 GO_ID=… zum Persistieren.)"
      return
    end

    ActiveRecord::Base.transaction do
      league = upsert(League, { game_operation_id: go_id, season_id: league_attrs[:season_id], name: liga['name'] },
                      LegacyImport::Transformer.league_attrs(liga, game_operation_id: go_id))

      team_map = {}
      mannschaften.each do |m|
        club = find_or_create_club(verein_names[m['id_verein'].to_i])
        attrs = LegacyImport::Transformer.team_attrs(m, league_id: league.id, club_id: club&.id)
        team_map[m['id_mannschaft'].to_i] = upsert(Team, { league_id: league.id, name: m['name'] }, attrs)
      end

      gd_map = {}
      spieltage.each do |s|
        arena = find_or_create_arena(spielort_names[s['id_spielort'].to_i])
        attrs = LegacyImport::Transformer.game_day_attrs(s, league_id: league.id, arena_id: arena&.id, club_id: nil)
        gd_map[s['id_spieltag'].to_i] = upsert(GameDay, { league_id: league.id, number: s['spieltag_nr'].to_i, date: s['datum'].to_s }, attrs)
      end

      games = 0
      begegnungen.each do |b|
        bid = b['id_begegnung'].to_i
        gd  = gd_map[b['id_spieltag'].to_i]
        home = team_map[b['id_mannschaft1'].to_i]
        guest = team_map[b['id_mannschaft2'].to_i]
        next unless gd && home && guest

        attrs = LegacyImport::Transformer.game_attrs(b, game_day_id: gd.id, home_team_id: home.id, guest_team_id: guest.id)
        attrs[:events]  = LegacyImport::Transformer.build_events(ev_by_beg[bid] || [])
        attrs[:players] = LegacyImport::Transformer.build_players(ms_by_beg[bid] || [])
        upsert(Game, { game_day_id: gd.id, home_team_id: home.id, guest_team_id: guest.id }, attrs)
        games += 1
      end

      puts "\n  Geschrieben: League ##{league.id}, #{team_map.size} Teams, #{gd_map.size} Spieltage, #{games} Spiele."
    end
    puts '  Tipp: Rails.cache.delete("settings/init") nach Vollimport nicht vergessen.'
  end

  def report_sample(begegnungen, ev_by_beg, ms_by_beg)
    sample = begegnungen.find { |b| ev_by_beg[b['id_begegnung'].to_i].present? } || begegnungen.first
    return unless sample

    sid = sample['id_begegnung'].to_i
    events = LegacyImport::Transformer.build_events(ev_by_beg[sid] || [])
    players = LegacyImport::Transformer.build_players(ms_by_beg[sid] || [])
    last = events.last
    puts "\n  Beispielspiel (Begegnung #{sid}, Spielnr #{sample['spielnummer']}):"
    puts "    Events: #{events.size}, Endstand #{last ? "#{last['home_goals']}:#{last['guest_goals']}" : 'n/a'}"
    puts "    Aufstellung: #{players['home'].size} Heim / #{players['guest'].size} Gast"
    puts "    events[0..1] = #{events.first(2).to_json}"
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────
  def legacy_mysql_client
    require 'mysql2'
    require 'uri'
    url = URI.parse(ENV.fetch('LEGACY_MYSQL_URL'))
    Mysql2::Client.new(host: url.host, port: url.port || 3306, username: url.user,
                       password: url.password, database: url.path.delete_prefix('/'), encoding: 'utf8')
  rescue LoadError
    abort 'Gem "mysql2" fehlt – nutze stattdessen legacy:league_json mit einem JSON-Bundle.'
  end

  def query_all(client, sql)
    client.query(sql, as: :hash).to_a
  end

  def query_one(client, sql)
    query_all(client, sql).first
  end

  def name_map(client, table, id_col, name_col)
    query_all(client, "SELECT #{id_col}, #{name_col} FROM #{table}").to_h { |r| [r[id_col].to_i, r[name_col]] }
  rescue StandardError
    {}
  end

  # Idempotenter Upsert: über find_by-Schlüssel suchen, sonst neu anlegen, dann
  # Attribute aktualisieren. validate: false, weil Altdaten Pflichtfelder/
  # Workflows des Livebetriebs nicht erfüllen (Spiele sind legacy = true).
  def upsert(klass, find_keys, attrs)
    record = klass.find_or_initialize_by(find_keys)
    record.assign_attributes(attrs)
    record.save!(validate: false)
    record
  end

  def find_or_create_club(name)
    return nil if name.blank?

    Club.find_or_create_by!(name:)
  end

  def find_or_create_arena(name)
    return nil if name.blank?

    Arena.find_or_create_by!(name:)
  end

  def warn_unmapped(league_attrs, liga)
    if league_attrs[:league_class_id].nil?
      puts "  ⚠ Klasse id_klasse=#{liga['id_klasse']} (#{liga['klasse_name']}) ohne league_class_id-Mapping!"
    end
    puts "  ⚠ field_size leer (kategorie=#{liga['id_kategorie']})" if league_attrs[:field_size].nil?
  end
end
