# frozen_string_literal: true

# lib/tasks/import_old_seasons.rake
#
# PoC: Rekonstruktion der Alt-Saisons 2010/11–2013/14 aus den MariaDB-Dumps des
# Vorgängersystems (Tabellen-Präfix `<verband>_<saison>_*`, siehe
# produktivdaten/MAPPING_KONZEPT_altdaten_2010-2014.md und
# docs/legacy_import_2010-2014.md).
#
# Default ist ein DRY-RUN (liest, transformiert, reportet – schreibt NICHT).
# Mit WRITE=1 werden Liga/Teams/Spieltage/Spiele idempotent angelegt.
#
# Import läuft SAISONWEIT in zwei Phasen über alle Verbände einer Saison:
#   Phase 1: Ligen + Teams (team_map Key (verband, id_mannschaft))
#   Phase 2: Spieltage + Spiele; Heim/Gast aus der Map, effektiver Verband aus
#            begegnung.id_verband_team1/2 → so lösen auch verbandsübergreifende
#            Wettbewerbe (FD-Pokal, Deutsche Meisterschaften) ihre Teams auf.
# Spieler-Lineups werden via PlayerResolver (Name+Geburtsdatum) auf echte
# Player-IDs gemappt.
#
# Tasks:
#   legacy:league       – eine Liga direkt aus MariaDB (benötigt Gem mysql2)
#   legacy:league_json  – eine Liga aus einem Single-Liga-JSON-Bundle
#   legacy:bundle       – ein Verband-/Saison-Bundle
#   legacy:dir          – alle *_bundle.json eines Ordners (nach Saison gruppiert)

namespace :legacy do
  desc 'PoC: eine Alt-Liga aus MariaDB importieren (Dry-Run; WRITE=1 schreibt)'
  task league: :environment do
    verband = ENV.fetch('VERBAND')
    season  = ENV.fetch('SEASON')
    liga_id = ENV.fetch('LIGA').to_i
    # Tabellen-Präfix ist vertrauenswürdige Operator-Eingabe und wird in SQL
    # interpoliert → gegen die bekannten Verbände/das Saison-Format absichern.
    abort "Unbekannter VERBAND #{verband.inspect}" unless LegacyImport::Vocab::VERBAND_GO.key?(verband)
    abort "SEASON muss YYYY_YYYY sein, war #{season.inspect}" unless season.match?(/\A\d{4}_\d{4}\z/)
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
    betreuer     = beg_ids.empty? ? [] : query_all(client, "SELECT * FROM `#{prefix}_betreuer` WHERE id_begegnung IN (#{beg_ids.join(',')})")
    spielbericht = beg_ids.empty? ? [] : query_all(client, "SELECT * FROM `#{prefix}_spielbericht` WHERE id_begegnung IN (#{beg_ids.join(',')})")
    mann_ids     = mannschaften.map { |m| m['id_mannschaft'].to_i }
    lizenz        = mann_ids.empty? ? [] : query_all(client, "SELECT * FROM `#{prefix}_lizenz` WHERE id_mannschaft IN (#{mann_ids.join(',')})")
    liz_ids       = lizenz.map { |l| l['id_lizenz'].to_i }
    lizenzverlauf = liz_ids.empty? ? [] : query_all(client, "SELECT * FROM `#{prefix}_lizenzverlauf` WHERE id_lizenz IN (#{liz_ids.join(',')})")
    spieler_ids  = mitspieler.map { |m| m['id_spieler'].to_i }.select(&:positive?).uniq
    spieler      = spieler_ids.empty? ? {} : query_all(client, "SELECT id_spieler, name, vorname, geb_datum, geschlecht FROM global_spieler WHERE id_spieler IN (#{spieler_ids.join(',')})").to_h { |r| [r['id_spieler'].to_s, r] }

    entry = { 'liga' => liga, 'mannschaft' => mannschaften, 'spieltag' => spieltage,
              'begegnung' => begegnungen, 'ereignis' => ereignisse, 'mitspieler' => mitspieler,
              'betreuer' => betreuer, 'spielbericht' => spielbericht,
              'lizenz' => lizenz, 'lizenzverlauf' => lizenzverlauf }
    import_bundles([{ 'verband' => verband, 'season' => season, 'leagues' => [entry], 'spieler' => spieler,
                      'vereine' => record_map(client, 'global_verein', 'id_verein', %w[name kurzname kuerzel strasse hausnummer plz ort]),
                      'spielorte' => record_map(client, 'global_spielort', 'id_spielort', %w[name strasse hausnummer plz ort]) }])
  end

  desc 'Preflight: prüft Voraussetzungen für den Altdaten-Import (read-only)'
  task prepare: :environment do
    puts "\n##### Preflight Altdaten-Import #####"

    seasons = Setting.current.seasons || {}
    %w[2 3 4 5].each do |sid|
      s = seasons[sid]
      puts s ? "  ✓ Saison #{sid} vorhanden: #{s['name']}" : "  ✗ Saison #{sid} FEHLT in Setting.seasons – vor dem Import anlegen"
    end

    pen = Setting.current.penalties || {}
    without_mapping = pen.reject { |_k, v| v.is_a?(Hash) && v['mapping'].present? }.keys
    if without_mapping.empty?
      puts '  ✓ Strafen haben mapping (Scorerwertung vollständig)'
    else
      puts "  ⚠ Strafen ohne 'mapping': #{without_mapping.join(', ')} – Strafstatistik bleibt leer (Scorer läuft trotzdem)"
    end

    min_l = Setting.current_min_league
    min_t = Setting.current_min_team
    if min_l.to_i.positive? || min_t.to_i.positive?
      puts "  ⚠ current_min_league=#{min_l}, current_min_team=#{min_t}: frisch importierte Legacy-Ligen/Teams bekommen"
      puts '    HÖHERE IDs und würden in Team.current_season (>= min) der aktuellen Saison auftauchen.'
      puts '    Empfehlung: Altdaten vor dem Anlegen der aktuellen Saison importieren oder min-Schwellen prüfen.'
    else
      puts "  ✓ current_min_league/current_min_team = 0 (keine ID-Schwellen-Kollision)"
    end
    puts '#####'
  end

  desc 'PoC: eine Alt-Liga aus einem Single-Liga-JSON-Bundle importieren'
  task league_json: :environment do
    b = load_bundle
    import_bundles([b.merge('leagues' => [b])])
  end

  desc 'PoC: ein Verband-/Saison-Bundle importieren'
  task bundle: :environment do
    import_bundles([load_bundle])
  end

  desc 'PoC: ALLE *_bundle.json eines Ordners importieren (nach Saison gruppiert)'
  task dir: :environment do
    require 'json'
    files = Dir.glob(File.join(ENV.fetch('DIR'), '*_bundle.json')).sort
    abort "Keine *_bundle.json in #{ENV['DIR']}" if files.empty?
    import_bundles(files.map { |p| JSON.parse(File.read(p)) })
  end

  # ── Orchestrierung ────────────────────────────────────────────────────────────
  def import_bundles(bundles)
    puts "\n##### #{bundles.size} Bundle(s), write=#{write?} #####"
    if write?
      bundles.group_by { |b| b['season'] }.each { |season, bs| run_season(season, bs) }
    else
      bundles.each do |b|
        go = go_id_for(b['verband'])
        (b['leagues'] || []).each { |e| dry_run_report(e, b['verband'], b['season'], go) }
      end
      puts "\n(DRY-RUN – nichts geschrieben. WRITE=1 zum Persistieren.)"
    end
  end

  # Alle Verbände einer Saison in einer Transaktion, drei Phasen
  # (Ligen/Teams → Spieltage/Spiele → Lizenzen).
  def run_season(season, bundles)
    puts "\n### Saison #{season}: #{bundles.map { |b| b['verband'] }.join(', ')} ###"
    ActiveRecord::Base.transaction do
      team_map = {}    # [verband, id_mannschaft] → Team
      league_recs = {} # [verband, id_liga]       → League
      player_maps = {} # verband → { alt id_spieler → Player.id } (in Phase 2 befüllt)

      # Phase 1 – Ligen + Teams
      bundles.each do |b|
        verband = b['verband']
        go_id = go_id_for(verband)
        abort "Unbekannter Verband #{verband} (kein GO)" if go_id.nil?
        vereine = indexed(b['vereine'])
        (b['leagues'] || []).each do |entry|
          next if empty_league?(entry) # leere Platzhalterligen (z. B. "… (falsch)") überspringen

          liga = entry['liga']
          league = upsert(League, "L:#{verband}:#{season}:#{liga['id_liga']}",
                          LegacyImport::Transformer.league_attrs(liga, game_operation_id: go_id))
          league_recs[[verband, liga['id_liga'].to_i]] = league
          (entry['mannschaft'] || []).each do |m|
            club = match_or_create_club(vereine[m['id_verein'].to_i])
            attrs = LegacyImport::Transformer.team_attrs(m, league_id: league.id, club_id: club&.id)
            team_map[[verband, m['id_mannschaft'].to_i]] = upsert(Team, "T:#{verband}:#{season}:#{m['id_mannschaft']}", attrs)
          end
        end
      end

      # Phase 2 – Spieltage + Spiele. Bewusst eine zweite Iteration über alle
      # Bundles: Phase 1 muss team_map/league_recs erst verbandsübergreifend
      # vollständig aufbauen, bevor hier Spiele geschrieben werden.
      # rubocop:disable Style/CombinableLoops
      bundles.each do |b|
        verband = b['verband']
        spielorte = indexed(b['spielorte'])
        player_id_map = resolve_or_create_players(verband, b['spieler'])
        player_maps[verband] = player_id_map
        (b['leagues'] || []).each do |entry|
          league = league_recs[[verband, entry['liga']['id_liga'].to_i]]
          next if league.nil? # übersprungene leere Liga

          write_games(entry, league, verband, season, team_map, spielorte, player_id_map)
        end
      end

      # Phase 3 – Lizenzen in player.licenses mergen (idempotent über license 'id').
      # Braucht team_map (Phase 1) + player_maps (Phase 2) → dritte Iteration.
      bundles.each do |b|
        verband = b['verband']
        pmap = player_maps[verband] || {}
        (b['leagues'] || []).each do |entry|
          next if empty_league?(entry)

          merge_licenses(entry, verband, season, team_map, pmap)
        end
      end
      # rubocop:enable Style/CombinableLoops
    end
    puts "### Saison #{season} fertig. ###"
  end

  # Reine Registrierungs-/Platzhalterliga ohne Spiele und ohne eigene Teams.
  def empty_league?(entry)
    (entry['begegnung'] || []).empty? && (entry['mannschaft'] || []).empty?
  end

  def write_games(entry, league, verband, season, team_map, spielorte, player_id_map)
    ev_by_beg = (entry['ereignis'] || []).group_by { |e| e['id_begegnung'].to_i }
    ms_by_beg = (entry['mitspieler'] || []).group_by { |m| m['id_begegnung'].to_i }
    bt_by_beg = (entry['betreuer'] || []).group_by { |x| x['id_begegnung'].to_i }
    sb_by_beg = (entry['spielbericht'] || []).index_by { |x| x['id_begegnung'].to_i }
    spieltag_by_id = (entry['spieltag'] || []).index_by { |s| s['id_spieltag'].to_i }
    gd_cache = {} # Spieltag lazy – nur wenn ein Spiel ihn nutzt (keine verwaisten GameDays)

    written = 0
    skipped = 0
    (entry['begegnung'] || []).each do |b|
      bid = b['id_begegnung'].to_i
      st = spieltag_by_id[b['id_spieltag'].to_i]
      home = team_map[[eff_verband(b, 1, verband), b['id_mannschaft1'].to_i]]
      guest = team_map[[eff_verband(b, 2, verband), b['id_mannschaft2'].to_i]]
      if st.nil? || home.nil? || guest.nil?
        skipped += 1
        next
      end

      gd = gd_cache[st['id_spieltag'].to_i] ||= begin
        arena = match_or_create_arena(spielorte[st['id_spielort'].to_i])
        attrs = LegacyImport::Transformer.game_day_attrs(st, league_id: league.id, arena_id: arena&.id, club_id: nil)
        upsert(GameDay, "GD:#{verband}:#{season}:#{st['id_spieltag']}", attrs)
      end

      attrs = LegacyImport::Transformer.game_attrs(b, game_day_id: gd.id, home_team_id: home.id, guest_team_id: guest.id)
      attrs.merge!(LegacyImport::Transformer.spielbericht_attrs(sb_by_beg[bid]))
      coaches = LegacyImport::Transformer.build_coaches(bt_by_beg[bid] || [])
      attrs[:home_team_coaches]  = coaches['home']  if coaches['home'].present?
      attrs[:guest_team_coaches] = coaches['guest'] if coaches['guest'].present?
      attrs[:events]  = LegacyImport::Transformer.build_events(ev_by_beg[bid] || [])
      attrs[:players] = LegacyImport::Transformer.build_players(ms_by_beg[bid] || [], player_id_map:)
      upsert(Game, "G:#{verband}:#{season}:#{b['id_begegnung']}", attrs)
      written += 1
    end

    note = skipped.positive? ? " (#{skipped} übersprungen: Team/Spieltag nicht auflösbar)" : ''
    puts "  → League ##{league.id} #{league.name}: #{written} Spiele#{note}"
  end

  # global_*_lizenz + *_lizenzverlauf → player.licenses. Spieler via player_id_map
  # (Name+Geburtsdatum), Team via team_map. Nicht auflösbare Lizenzen (Spieler/Team
  # unbekannt) werden gezählt, nicht still verworfen. Legacy-Teams liegen außerhalb
  # von current_min_team → die importierten Lizenzen tauchen nicht in der aktuellen
  # Saison auf.
  #
  # Idempotenz: Der Merge dedupliziert PRO SPIELER über die license 'id'
  # (LIC:<verband>:<saison>:<id_lizenz>) – ein zweiter Lauf ersetzt den Eintrag
  # statt anzuhängen. Forward-only wie der übrige Import: matcht eine id_spieler
  # zwischen zwei Läufen auf einen ANDEREN Spieler (geänderter player_index),
  # bleibt der alte Eintrag beim zuvor gematchten Spieler stehen. Für einen echten
  # Re-Import nach Änderung der Spieler-Basis ggf. die LIC:-Einträge vorab wegräumen.
  def merge_licenses(entry, verband, season, team_map, player_id_map)
    lizenzen = entry['lizenz'] || []
    return if lizenzen.empty?

    verlauf_by_lizenz = (entry['lizenzverlauf'] || []).group_by { |v| v['id_lizenz'].to_i }
    by_player = Hash.new { |h, k| h[k] = [] }
    unresolved = 0

    lizenzen.each do |lz|
      pid = player_id_map[lz['id_spieler'].to_i]
      team = team_map[[verband, lz['id_mannschaft'].to_i]]
      if pid.nil? || team.nil?
        unresolved += 1
        next
      end
      license_id = "LIC:#{verband}:#{season}:#{lz['id_lizenz']}"
      by_player[pid] << LegacyImport::Transformer.license_attrs(
        lz, verlauf_by_lizenz[lz['id_lizenz'].to_i], team_id: team.id, license_id:
      )
    end

    by_player.each do |pid, new_lics|
      player = Player.find_by(id: pid)
      next unless player

      kept = (player.licenses || []).reject { |l| new_lics.any? { |n| n['id'] == l['id'] } }
      player.licenses = kept + new_lics
      player.save!(validate: false)
    end

    note = unresolved.positive? ? " (#{unresolved} ohne Spieler/Team-Match)" : ''
    puts "  Lizenzen #{verband}: #{lizenzen.size - unresolved}/#{lizenzen.size} → #{by_player.size} Spieler#{note}"
  end

  def dry_run_report(entry, verband, season, go_id)
    liga = entry['liga']
    league_attrs = LegacyImport::Transformer.league_attrs(liga, game_operation_id: go_id || 0)
    games = entry['begegnung'] || []
    puts "\n=== #{verband}_#{season} ##{liga['id_liga']}: #{liga['name']} (Saison #{league_attrs[:season_id]}) – #{games.size} Spiele ==="
    warn_unmapped(league_attrs, liga)
    ev_by_beg = (entry['ereignis'] || []).group_by { |e| e['id_begegnung'].to_i }
    sample = games.find { |b| ev_by_beg[b['id_begegnung'].to_i].present? }
    return unless sample

    events = LegacyImport::Transformer.build_events(ev_by_beg[sample['id_begegnung'].to_i])
    last = events.last
    puts "  Beispiel Begegnung #{sample['id_begegnung']}: #{events.size} Events, Endstand #{last['home_goals']}:#{last['guest_goals']}"
    lic_count = (entry['lizenz'] || []).size
    puts "  Lizenzen: #{lic_count}" if lic_count.positive?
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────
  # Effektiver Verband eines Teams: bei verbandsübergreifenden Spielen steht der
  # echte Verband in begegnung.id_verband_team{side}, sonst der eigene.
  def eff_verband(begegnung, side, own_verband)
    vt = begegnung["id_verband_team#{side}"].to_i
    vt.positive? ? (LegacyImport::Vocab::VERBAND_ID_PATH[vt] || own_verband) : own_verband
  end

  # DB-weiter Player-Index (Nachname|Vorname|Geburtsdatum → id), einmal je Prozess.
  # WICHTIG: nur `birthdate: nil` ausschließen, NICHT `[nil, '']`. players.birthdate
  # ist eine DATE-Spalte; der Vergleich gegen den Leerstring '' castet zu NULL und
  # `where.not(birthdate: [nil, ''])` liefert dann DB-weit 0 Zeilen → leerer Index →
  # jeder Spieler wird als Dublette neu angelegt statt gegen den Bestand gematcht.
  def player_index
    @player_index ||= LegacyImport::PlayerResolver.build_index(
      Player.where.not(birthdate: nil).pluck(:last_name, :first_name, :birthdate, :id)
    )
  end

  # Alte id_spieler → neue Player.id. Erst gegen den Live-Bestand matchen
  # (Name+Geburtsdatum); fehlende Spieler werden – konservativ NUR mit Geburtsdatum –
  # angelegt und im Namensindex registriert (idempotent: Re-Runs matchen sie, kein
  # Duplikat; Spieler ohne Geburtsdatum bleiben im Lineup denormalisiert). Schiris
  # werden bewusst NICHT angelegt (bleiben Freitext).
  def resolve_or_create_players(verband, spieler_map)
    map = LegacyImport::PlayerResolver.resolve(spieler_map, player_index)
    matched = map.size
    created = 0
    reused = 0

    (spieler_map || {}).each do |old_id, data|
      oid = old_id.to_i
      next if map.key?(oid) || !valid_birthdate?(data['geb_datum'])

      key = LegacyImport::PlayerResolver.key(data['name'], data['vorname'], data['geb_datum'])
      # Namensgleiche mit identischem Geburtsdatum (auch ein eben erst angelegter
      # Spieler) auf denselben Datensatz abbilden statt zu duplizieren.
      if (existing_id = player_index[key])
        map[oid] = existing_id
        reused += 1
        next
      end

      player = Player.new(LegacyImport::Transformer.player_attrs(data))
      player.save!(validate: false)
      player_index[key] = player.id
      map[oid] = player.id
      created += 1
    end

    total = (spieler_map || {}).size
    if total.positive?
      puts "  [#{verband}] Spieler: #{matched} gematcht, #{created} angelegt, #{reused} per Namensgleichheit verknüpft, " \
           "#{total - matched - created - reused} ohne gültiges Geburtsdatum übersprungen (von #{total})"
    end
    map
  end

  # Plausibles Geburtsdatum (YYYY-MM-DD, Jahr != 0000). MariaDB-Nulldaten
  # ("0000-00-00") gelten als fehlend → kein Spieler wird dafür angelegt.
  def valid_birthdate?(geb_datum)
    str = geb_datum.to_s.strip
    str.match?(/\A\d{4}-\d{2}-\d{2}/) && !str.start_with?('0000')
  end

  def write?
    ENV['WRITE'] == '1'
  end

  def go_id_for(verband)
    ENV['GO_ID']&.to_i || LegacyImport::Vocab::VERBAND_GO[verband]
  end

  def load_bundle
    require 'json'
    JSON.parse(File.read(ENV.fetch('BUNDLE')))
  end

  def indexed(hash)
    (hash || {}).transform_keys(&:to_i)
  end

  def legacy_mysql_client
    require 'mysql2'
    require 'uri'
    url = URI.parse(ENV.fetch('LEGACY_MYSQL_URL'))
    Mysql2::Client.new(host: url.host, port: url.port || 3306, username: url.user,
                       password: url.password, database: url.path.delete_prefix('/'), encoding: 'utf8')
  rescue LoadError
    abort 'Gem "mysql2" fehlt – nutze stattdessen legacy:league_json / legacy:bundle / legacy:dir mit JSON-Bundles.'
  end

  def query_all(client, sql)
    client.query(sql, as: :hash).to_a
  end

  def query_one(client, sql)
    query_all(client, sql).first
  end

  # id → vollständiger Datensatz (für die Anlage fehlender Stammdaten).
  def record_map(client, table, id_col, cols)
    query_all(client, "SELECT #{id_col}, #{cols.join(', ')} FROM #{table}").to_h { |r| [r[id_col].to_i, r] }
  rescue StandardError
    {}
  end

  # Idempotenter Upsert über die herkunftsstabile legacy_ref (z. B.
  # "L:fvd:2013_2014:33"). Re-Runs aktualisieren denselben Datensatz, auch bei
  # Umbenennungen oder doppelten Paarungen. validate: false, weil Altdaten
  # Pflichtfelder/Workflows des Livebetriebs nicht erfüllen (legacy = true).
  def upsert(klass, legacy_ref, attrs)
    record = klass.find_or_initialize_by(legacy_ref:)
    record.assign_attributes(attrs)
    record.save!(validate: false)
    record
  end

  # Verein über den normalisierten Namen gegen den Live-Bestand matchen
  # (name/short_name/long_name); bei keinem Treffer aus dem Alt-Record anlegen.
  # Der frisch angelegte Verein wird im Index registriert → idempotent (Re-Runs
  # matchen ihn, kein Duplikat) und innerhalb eines Laufs wiederverwendbar.
  def match_or_create_club(record)
    return nil if record.nil? || record['name'].blank?

    key = norm_name(record['name'])
    cid = club_index[key]
    return Club.find_by(id: cid) if cid

    club = Club.new(LegacyImport::Transformer.club_attrs(record))
    club.save!(validate: false)
    club_index[key] = club.id
    club
  end

  # Spielort über den normalisierten Namen matchen; bei keinem Treffer anlegen.
  def match_or_create_arena(record)
    return nil if record.nil? || record['name'].blank?

    key = norm_name(record['name'])
    aid = arena_index[key]
    return Arena.find_by(id: aid) if aid

    arena = Arena.new(LegacyImport::Transformer.arena_attrs(record))
    arena.save!(validate: false)
    arena_index[key] = arena.id
    arena
  end

  # name/short_name/long_name (Club) bzw. name (Arena), normalisiert → id. Erste
  # Belegung gewinnt; einmal je Prozess gebaut.
  def club_index
    @club_index ||= build_name_index(Club.pluck(:id, :name, :short_name, :long_name))
  end

  def arena_index
    @arena_index ||= build_name_index(Arena.pluck(:id, :name))
  end

  def build_name_index(rows)
    idx = {}
    rows.each do |id, *names|
      names.each do |n|
        k = norm_name(n)
        idx[k] ||= id if k.present?
      end
    end
    idx
  end

  # Vereinsnamen vergleichbar machen: Kleinschreibung, Rechtsform/Sonderzeichen weg.
  def norm_name(str)
    str.to_s.downcase.gsub(/e\.?\s*v\.?\z/, '').gsub(/[^a-z0-9]+/, ' ').strip
  end

  def warn_unmapped(league_attrs, liga)
    return if league_attrs[:league_class_id].present?

    puts "  ⚠ Klasse id_klasse=#{liga['id_klasse']} (#{liga['klasse_name']}) ohne league_class_id-Mapping"
  end
end
