module PlayerStats
  # Schreibt das Spielerdaten-Aggregat neu (player_game_stats) und dazu den
  # Heimatvereins-Schnappschuss (player_stat_profiles).
  #
  # Gerechnet wird liga-weise, und je Liga wird geloescht und neu eingefuegt statt
  # aufaddiert. Nur so verschwindet auch etwas wieder: Ein zurueckgenommenes Tor, ein
  # geloeschtes Spiel oder eine korrigierte Aufstellung wuerde ein aufsummierender Lauf
  # nie mehr los, und der Fehler waere in der Rangliste nicht zu erkennen.
  #
  # Der Lauf ist idempotent und speicherbegrenzt: Im Speicher steht immer nur eine
  # Liga, die Spiele kommen in Batches.
  #
  # Bewusst KEIN inkrementeller Lauf ueber games.updated_at. Korrekturen an Altspielen
  # laufen hier reihenweise ueber update_column (fix_imported_game_format,
  # clear_premature_placement_teams, freeze_imported_penalty_labels), und das ruehrt
  # updated_at nicht an -- ein Wasserzeichen wuerde genau diese Korrekturen dauerhaft
  # uebersehen. SEASON_ID/LEAGUE_ID gibt es fuer den gezielten Nachlauf am Tag.
  class Refresher
    GAME_BATCH = 200
    SKIPPED_REPORT_KEY = 'player_stats/skipped_games'.freeze
    INSERT_SLICE = 1000
    PROFILE_BATCH = 1000

    def initialize(season_id: nil, league_id: nil, dry_run: false, progress: nil)
      @season_id = season_id.presence&.to_s
      @league_id = league_id.presence&.to_i
      @dry_run = dry_run
      @progress = progress
      @computed_at = Time.current
    end

    def run!
      started = Time.current
      leagues = rows = skipped_games = 0

      league_scope.find_each(batch_size: 50) do |league|
        result = refresh_league(league)
        leagues += 1
        rows += result[:rows]
        skipped_games += result[:skipped]
        report("--- Liga ##{league.id} [#{league.season_id}] #{league.name}: " \
               "#{result[:rows]} Zeilen#{result[:skipped].positive? ? ", #{result[:skipped]} Spiele uebersprungen" : ''}")
      end

      # Nur der volle Lauf raeumt auf und schreibt den Schnappschuss: Ein Nachlauf fuer
      # eine Saison weiss nichts ueber die uebrigen und wuerde deren Zeilen als verwaist
      # ansehen.
      orphans = full? ? remove_orphans : 0
      profiles = full? ? refresh_profiles : 0
      report_skipped_games(skipped_games) if full?

      { leagues:, rows:, skipped_games:, orphans:, profiles:,
        computed_at: @computed_at, seconds: (Time.current - started).round(1) }
    end

    private

    # Uebersprungene Spiele muessen aus dem Lauf herauskommen.
    #
    # Der rescue je Spiel ist richtig -- ein kaputtes Spiel darf die Liga nicht
    # mitreissen --, aber der Lauf ist unbeaufsichtigt: Er endet mit Exit 0, der
    # Endpunkt antwortet weiter mit 200, und die einzige Spur ist eine Zeile in
    # /var/log/player_stats.log. Bricht evaluate_scorer durch eine Datenaenderung
    # reihenweise weg, sinken die Zahlen der Rangliste still.
    #
    # Deshalb dieselbe Behandlung wie bei einer unlesbaren Zugehoerigkeit
    # (Player#report_membership_date_defect): melden, und hoechstens einmal am Tag,
    # damit ein Nachlauf am selben Tag nicht nachlegt.
    #
    # Ein Probelauf meldet nichts: DRY_RUN schreibt nicht und markiert nicht.
    def report_skipped_games(count)
      return if count.zero? || @dry_run
      return unless Rails.cache.write(SKIPPED_REPORT_KEY, true, unless_exist: true, expires_in: 1.day)

      message = "PlayerStats::Refresher: #{count} Spiel(e) uebersprungen -- " \
                'die Spielerdaten-Rangliste zaehlt sie nicht mit'
      Rails.logger.error(message)
      Sentry.capture_message(message) if defined?(Sentry)
    end

    def full?
      @season_id.nil? && @league_id.nil?
    end

    # League.unscoped: Der default_scope der Liga sortiert nach season_id,
    # game_operation_id und order_key -- fuer einen Batch-Durchlauf nutzlos, und
    # find_each verwirft die Sortierung ohnehin.
    def league_scope
      scope = League.unscoped
      scope = scope.where(season_id: @season_id) if @season_id
      scope = scope.where(id: @league_id) if @league_id
      scope
    end

    def refresh_league(league)
      totals, skipped = collect(league)
      rows = build_rows(league, totals)

      unless @dry_run
        PlayerGameStat.transaction do
          PlayerGameStat.where(league_id: league.id).delete_all
          rows.each_slice(INSERT_SLICE) { |slice| PlayerGameStat.insert_all(slice) }
        end
      end

      { rows: rows.size, skipped: }
    end

    # (player_id, team_id) => Zaehler, ueber alle beendeten Spiele der Liga.
    #
    # Game#evaluate_scorer liefert bei einem kampflosen Spiel bewusst ein leeres
    # Ergebnis (forfait?), ein solches Spiel zaehlt hier also nicht als Einsatz --
    # dieselbe Regel wie in der Scorerliste und im Spielerprofil.
    def collect(league)
      totals = {}
      skipped = 0

      games_of(league).find_each(batch_size: GAME_BATCH) do |game|
        game.evaluate_scorer.each do |player_id, score|
          next if player_id.blank? || score[:team_id].blank?

          entry = (totals[[player_id.to_i, score[:team_id].to_i]] ||=
                     { games: 0, goals: 0, assists: 0, penalty_minutes: 0 })
          entry[:games] += 1
          entry[:goals] += score[:goals].to_i
          entry[:assists] += score[:assists].to_i
          entry[:penalty_minutes] += PlayerStats.penalty_minutes(score)
        end
      rescue StandardError => e
        # Ein einzelnes kaputtes Spiel (fehlende Mannschaft, unlesbare Aufstellung)
        # darf den Lauf nicht abbrechen -- sonst fehlt die ganze Liga. Gleiche
        # Entscheidung wie in TeamsController#collect_scorer_stores, nur mit Zaehler,
        # damit es in der Ausgabe des Laufs sichtbar bleibt.
        skipped += 1
        Rails.logger.warn("PlayerStats::Refresher: Spiel ##{game.id} uebersprungen (#{e.class}: #{e.message})")
      end

      [totals, skipped]
    end

    # Ueber game_day_id statt ueber League#games: letzteres laedt Spieltage, Hallen,
    # Vereine und beide Mannschaften samt Logos in den Speicher und sortiert in Ruby.
    # Gebraucht werden hier nur die Mannschaften, an denen evaluate_scorer haengt.
    def games_of(league)
      Game.where(ended: true, game_day_id: league.game_days.select(:id))
          .includes(:home_team, :guest_team)
    end

    def build_rows(league, totals)
      return [] if totals.empty?

      club_by_team = Team.where(id: totals.keys.map(&:last).uniq).pluck(:id, :club_id).to_h
      # Der Fremdschluessel auf players laesst keine Zeile zu einem geloeschten Profil
      # zu. In Altsaisons stehen solche IDs in den Aufstellungen; ohne diesen Abgleich
      # bricht der Lauf an der ganzen Liga statt an der einen Zeile.
      known_players = Player.where(id: totals.keys.map(&:first).uniq).pluck(:id).to_set

      totals.filter_map do |(player_id, team_id), counters|
        club_id = club_by_team[team_id]
        # Ohne Mannschaft kein Verein, und ohne Verein hat die Zeile in einer
        # Vereinsrangliste nichts verloren.
        next if club_id.nil? || !known_players.include?(player_id)

        {
          player_id:, team_id:, club_id:,
          league_id: league.id,
          season_id: league.season_id,
          game_operation_id: league.game_operation_id,
          league_class_id: league.league_class_id.presence,
          computed_at: @computed_at
        }.merge(counters)
      end
    end

    def remove_orphans
      return 0 if @dry_run

      PlayerGameStat.where.not(league_id: League.unscoped.select(:id)).delete_all
    end

    # Heimatverein je Profil, abgeleitet ueber Player#home_club_entry statt ueber
    # eigenes SQL: Es darf keinen zweiten Begriff von „Heimatverein" geben, und in SQL
    # waere er auch nicht sauber zu bilden (valid_until ist Freitext).
    #
    # Nebeneffekt, der so gewollt ist: Der Lauf liest damit jede Zugehoerigkeit einmal
    # taeglich und meldet unlesbare valid_until-Werte ueber den bestehenden Weg
    # (Player#report_membership_date_defect, je Profil hoechstens einmal am Tag).
    def refresh_profiles
      go_by_club = Club.all.to_h { |club| [club.id, club.main_game_operation_id] }
      written = 0

      Player.select(:id, :clubs).find_in_batches(batch_size: PROFILE_BATCH) do |batch|
        rows = batch.map do |player|
          entry = player.home_club_entry
          club_id = entry && entry['club_id'].to_i
          club_id = nil unless club_id&.positive?

          { player_id: player.id, home_club_id: club_id,
            home_game_operation_id: club_id && go_by_club[club_id],
            computed_at: @computed_at }
        end
        next if @dry_run

        PlayerStatProfile.upsert_all(rows, unique_by: :player_id, record_timestamps: false)
        written += rows.size
      end

      PlayerStatProfile.where.not(player_id: Player.select(:id)).delete_all unless @dry_run
      written
    end

    def report(message)
      @progress&.call(message)
    end
  end
end
