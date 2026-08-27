module Admin
  # Spielerdaten-Rangliste: Einsaetze, Tore, Vorlagen und Strafminuten je Person,
  # saisonuebergreifend, sortierbar und blaetterbar (Issue #465, Frontend #300).
  #
  # Zwei Modi, die DASSELBE zaehlen -- der Verbandsmodus ist die Vereinigung ueber die
  # Vereine des Landesverbands, nicht eine andere Rechnung:
  #
  #   club_id=42   Verein  – gezaehlt wird, was fuer diesen Verein gespielt wurde
  #   ohne club_id Verband – gezaehlt wird, was fuer die Vereine des eigenen
  #                          Spielbetriebs gespielt wurde (bundesweiter Scope: alles)
  #
  # Zugeordnet wird ueber die Mannschaft der Aufstellung (player_game_stats.club_id aus
  # teams.club_id), nicht ueber players.clubs. Sonst landeten Eins.aetze bei frueheren
  # Vereinen in der Vereinsstatistik. Spielgemeinschaften bleiben unberuecksichtigt
  # (Vorgabe aus #465).
  #
  # Gelesen wird ausschliesslich das naechtliche Aggregat (rake player_stats:refresh);
  # hier wird nichts gerechnet, was ein Spiel anfassen muesste.
  #
  # Kein Zugang per X-Api-Key: Eine vereins- oder verbandsweite Namensliste mit
  # Mannschaftszuordnung gehoert nicht in den oeffentlichen Bereich. players#stats
  # verzichtet aus demselben Grund auf Geburtsdatum und Geschlecht.
  class PlayerStatisticsController < ApplicationController
    include ClubListAccess

    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE = 200

    # Sortierschluessel als Weissliste. Die Werte gehen als SQL in ORDER BY, es darf
    # also nichts anderes als genau diese Ausdruecke hineinkommen.
    SORT_EXPRESSIONS = {
      'games' => 'SUM(player_game_stats.games)',
      'goals' => 'SUM(player_game_stats.goals)',
      'assists' => 'SUM(player_game_stats.assists)',
      'scorer_points' => '(SUM(player_game_stats.goals) + SUM(player_game_stats.assists))',
      'penalty_minutes' => 'SUM(player_game_stats.penalty_minutes)',
      # Division nur, wenn es etwas zu teilen gibt. min_games=0 laesst Zeilen ohne
      # Einsatz zu (gibt es im Bestand nicht, kostet aber nichts, es abzufangen).
      'scorer_per_game' => 'CASE WHEN SUM(player_game_stats.games) > 0 ' \
                           'THEN (SUM(player_game_stats.goals) + SUM(player_game_stats.assists))::numeric ' \
                           '/ SUM(player_game_stats.games) ELSE 0 END',
      'name' => 'players.last_name'
    }.freeze

    DEFAULT_SORT = 'games'.freeze

    # Saison-IDs sind eine Zeichenkette (leagues.season_id), fuer „erste bis letzte
    # Saison" wird aber numerisch verglichen. Der Regex-Riegel statt eines blanken
    # ::integer-Casts: Ein nicht-numerischer Eintrag im Bestand wuerde den ganzen
    # Endpunkt mit einem Datenbankfehler beenden, nicht nur diese eine Spalte.
    SEASON_NUMERIC = "CASE WHEN player_game_stats.season_id ~ '^[0-9]+$' " \
                     'THEN player_game_stats.season_id::integer END'.freeze

    # GET /api/v2/admin/player_statistics
    def index
      return unless authorize!

      rows = page_rows
      render json: {
        scope: scope_payload,
        as_of: rows.filter_map { |r| r['computed_at'] }.max,
        total: total_count,
        page: page,
        per_page: per_page,
        filters: filter_options,
        players: players_payload(rows)
      }
    rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
      # Wie in Admin::AnalyticsController: Ein Aggregat ist kein Kernbestand. Faellt es
      # aus, soll die Oberflaeche das sagen koennen, statt einen 500er zu zeigen.
      Rails.logger.error("PlayerStatisticsController#index failed: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      render json: { error: 'Spielerdaten konnten nicht geladen werden.' }, status: :service_unavailable
    end

    private

    # ------------------------------------------------------------------ Rechte

    def authorize!
      club_id.present? ? authorize_club! : authorize_association!
    end

    def authorize_club!
      unless club_list_access?(permission_hash, club_id)
        render json: { message: 'Keine Berechtigung.' }, status: :forbidden
        return false
      end
      unless club
        render json: { message: 'Verein nicht gefunden.' }, status: :not_found
        return false
      end
      true
    end

    # Der Verbandsmodus ist die Verwaltungssicht auf den eigenen Spielbetrieb und
    # deshalb an Admin oder SBK gebunden. Vereins- und Teammanager kommen ueber den
    # Vereinsmodus an genau ihre Vereine.
    def authorize_association!
      ph = permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        render json: { message: 'Keine Berechtigung.' }, status: :forbidden
        return false
      end
      # club_filter_id ist ein Filter, kein zweiter Zugang: Ein Verein ausserhalb des
      # eigenen Spielbetriebs wird abgewiesen, statt still eine leere Liste zu liefern.
      if params[:club_filter_id].present? && scope_club_ids &&
         !scope_club_ids.include?(params[:club_filter_id].to_i)
        render json: { message: 'Keine Berechtigung.' }, status: :forbidden
        return false
      end
      true
    end

    def permission_hash
      @permission_hash ||= current_user.permission_hash
    end

    def club_id
      @club_id ||= params[:club_id].presence&.to_i
    end

    def club
      return nil unless club_id

      @club ||= Club.find_by(id: club_id)
    end

    # Vereine im Blick. nil heisst „kein Vereinsfilter" (bundesweiter Scope) und ist
    # nicht dasselbe wie eine leere Liste.
    def scope_club_ids
      return [club_id] if club_id
      return @scope_club_ids if defined?(@scope_club_ids)

      ph = permission_hash
      @scope_club_ids =
        if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
          nil
        else
          # Rollen additiv: Ein regional gescopter Admin mit zusaetzlicher SBK-Rolle
          # verlöre sonst den einen oder den anderen Spielbetrieb.
          go_ids = [ph[:admin], ph[:sbk]].compact
          go_ids.flatten!
          derive_club_ids_for_go(go_ids)
        end
    end

    # Die Vereine, auf die die Zaehlung tatsaechlich laeuft -- inklusive des
    # Vereinsfilters der Verbandsansicht.
    def counted_club_ids
      return @counted_club_ids if defined?(@counted_club_ids)

      @counted_club_ids =
        if !club_id && params[:club_filter_id].present?
          [params[:club_filter_id].to_i]
        else
          scope_club_ids
        end
    end

    # ------------------------------------------------------------------ Abfrage

    # Basis fuer alles: die Zeilen im Blick, ohne die Filter der Oberflaeche.
    # Die Auswahllisten (filter_options) haengen an dieser Menge und nicht an der
    # gefilterten -- sonst raeumt der erste gesetzte Filter alle uebrigen Auswahlen leer.
    def scope_rows
      PlayerGameStat.for_clubs(counted_club_ids)
    end

    def filtered_rows
      scope = scope_rows
              .joins(:player)
              .joins('LEFT JOIN player_stat_profiles ON player_stat_profiles.player_id = player_game_stats.player_id')

      scope = scope.where(season_id: season_ids) if season_ids.present?
      scope = scope.where(game_operation_id: params[:game_operation_id].to_i) if params[:game_operation_id].present?
      scope = scope.where(league_id: params[:league_id].to_i) if params[:league_id].present?
      scope = scope.where(league_class_id: params[:league_class_id]) if params[:league_class_id].present?
      scope = scope.where(team_id: params[:team_id].to_i) if params[:team_id].present?
      scope = scope.where('LOWER(players.gender) = ?', params[:gender].to_s.downcase) if params[:gender].present?
      scope = scope.where(players: { deactivated_at: nil }) unless include_deactivated?
      if search_term.present?
        scope = scope.where('players.last_name ILIKE :q OR players.first_name ILIKE :q', q: "%#{search_term}%")
      end
      scope = apply_current_members(scope) if only_current_members?
      scope
    end

    # „nur aktuell gemeldete Spieler": Der laufende Heimatverein muss im Blick liegen.
    # Der Schnappschuss (player_stat_profiles) ist bis zu einen Tag alt und dient
    # ausschliesslich dieser Auswahl -- ueber Rechte entscheidet er nie.
    def apply_current_members(scope)
      if counted_club_ids
        scope.where(player_stat_profiles: { home_club_id: counted_club_ids })
      else
        scope.where.not(player_stat_profiles: { home_club_id: nil })
      end
    end

    def grouped_rows
      filtered_rows
        .group('players.id', 'player_stat_profiles.home_club_id')
        .having('SUM(player_game_stats.games) >= ?', min_games)
    end

    def page_rows
      sql = grouped_rows
            .select(
              'players.id AS player_id',
              'players.first_name AS first_name',
              'players.last_name AS last_name',
              'players.deactivated_at AS deactivated_at',
              'player_stat_profiles.home_club_id AS home_club_id',
              'SUM(player_game_stats.games) AS games',
              'SUM(player_game_stats.goals) AS goals',
              'SUM(player_game_stats.assists) AS assists',
              'SUM(player_game_stats.penalty_minutes) AS penalty_minutes',
              "MIN(#{SEASON_NUMERIC}) AS first_season_id",
              "MAX(#{SEASON_NUMERIC}) AS last_season_id",
              'MAX(player_game_stats.computed_at) AS computed_at'
            )
            .order(Arel.sql(order_clause))
            .limit(per_page)
            .offset((page - 1) * per_page)
            .to_sql

      PlayerGameStat.connection.select_all(sql).to_a
    end

    def total_count
      inner = grouped_rows.select('players.id').to_sql
      PlayerGameStat.connection.select_value("SELECT COUNT(*) FROM (#{inner}) AS treffer").to_i
    end

    def order_clause
      expression = SORT_EXPRESSIONS[sort_key]
      direction = params[:sort_dir].to_s.downcase == 'asc' ? 'ASC' : 'DESC'

      if sort_key == 'name'
        # Namen aufsteigend zu lesen ist der Normalfall, deshalb hier die andere
        # Vorbelegung; ausserdem der Vorname als zweiter Schluessel.
        direction = params[:sort_dir].to_s.downcase == 'desc' ? 'DESC' : 'ASC'
        return "players.last_name #{direction}, players.first_name #{direction}, players.id ASC"
      end

      # players.id als letzter Schluessel: Ohne ihn ist die Reihenfolge bei gleichen
      # Werten nicht festgelegt, und dieselbe Person taucht beim Blaettern zweimal
      # oder gar nicht auf.
      "#{expression} #{direction} NULLS LAST, players.last_name ASC, players.id ASC"
    end

    # ------------------------------------------------------------------ Parameter

    def sort_key
      key = params[:sort].to_s
      SORT_EXPRESSIONS.key?(key) ? key : DEFAULT_SORT
    end

    def season_ids
      # Mehrfachauswahl, als Array oder kommasepariert. Immer als String vergleichen:
      # leagues.season_id ist eine varchar-Spalte, und ein Range darauf zoege
      # stillschweigend die einstelligen Saisons mit.
      raw = params[:season_id]
      values = raw.is_a?(Array) ? raw : raw.to_s.split(',')
      values.map { |v| v.to_s.strip }.reject(&:blank?)
    end

    def min_games
      value = params[:min_games].presence&.to_i || 1
      value.negative? ? 0 : value
    end

    def page
      value = params[:page].to_i
      value.positive? ? value : 1
    end

    def per_page
      value = params[:per_page].presence&.to_i || DEFAULT_PER_PAGE
      value = DEFAULT_PER_PAGE unless value.positive?
      [value, MAX_PER_PAGE].min
    end

    def include_deactivated?
      ActiveModel::Type::Boolean.new.cast(params[:include_deactivated]) || false
    end

    # Standard an: Die Ansicht zeigt zuerst den heutigen Kader. Ausgeschaltet kommen
    # die ehemaligen dazu, mit ihren damaligen Spielen fuer diesen Verein -- die
    # Zaehlung aendert sich dabei nicht, nur die Auswahl.
    def only_current_members?
      return true if params[:only_current_members].blank?

      ActiveModel::Type::Boolean.new.cast(params[:only_current_members]) || false
    end

    def search_term
      @search_term ||= params[:q].to_s.strip
    end

    # ------------------------------------------------------------------ Antwort

    def scope_payload
      if club
        { mode: 'club', club: { id: club.id, name: club.name } }
      else
        { mode: 'association', global: scope_club_ids.nil? }
      end
    end

    def players_payload(rows)
      club_names = club_names_for(rows)

      rows.map do |row|
        games = row['games'].to_i
        goals = row['goals'].to_i
        assists = row['assists'].to_i
        points = goals + assists
        home_club_id = row['home_club_id']&.to_i

        entry = {
          player_id: row['player_id'].to_i,
          first_name: row['first_name'],
          last_name: row['last_name'],
          deactivated_at: row['deactivated_at'],
          games:, goals:, assists:,
          scorer_points: points,
          scorer_per_game: games.positive? ? (points.to_f / games).round(2) : 0.0,
          goals_per_game: games.positive? ? (goals.to_f / games).round(2) : 0.0,
          assists_per_game: games.positive? ? (assists.to_f / games).round(2) : 0.0,
          penalty_minutes: row['penalty_minutes'].to_i,
          first_season_id: row['first_season_id']&.to_s,
          last_season_id: row['last_season_id']&.to_s
        }
        # Der Verein steht nur in der Verbandsansicht; in der Vereinsansicht ist er
        # fuer jede Zeile derselbe.
        entry.merge!(home_club_id:, home_club: club_names[home_club_id]) unless club_id
        entry
      end
    end

    # Vereinsnamen frisch aufgeloest, nicht aus dem Schnappschuss: Eine Umbenennung
    # soll sofort durchschlagen. Gleiche Regel wie PlayersController#entry_with_names.
    def club_names_for(rows)
      return {} if club_id

      ids = rows.filter_map { |row| row['home_club_id']&.to_i }.uniq
      return {} if ids.empty?

      Club.where(id: ids).pluck(:id, :name).to_h
    end

    # Nur Werte, die im Bestand dieses Blicks wirklich vorkommen. Alles andere baute
    # Auswahlfelder, die zwangslaeufig leere Ergebnisse liefern.
    def filter_options
      options = {
        seasons: season_options,
        game_operations: game_operation_options,
        league_classes: league_class_options
      }

      if club_id
        # Liga und Mannschaft nur in der Vereinsansicht: Ueber einen ganzen
        # Landesverband und alle Saisons sind das tausende Eintraege, und eine
        # Auswahlliste dieser Groesse hilft niemandem.
        options[:leagues] = league_options
        options[:teams] = team_options
      else
        options[:clubs] = club_options
      end

      options
    end

    def season_options
      scope_rows.distinct.pluck(:season_id).compact_blank
                .sort_by { |season_id| -season_id.to_i }
                .map { |season_id| { id: season_id, name: Setting.season_name(season_id) || season_id } }
    end

    def game_operation_options
      ids = scope_rows.distinct.pluck(:game_operation_id).compact
      GameOperation.by_id.values_at(*ids).compact
                   .sort_by(&:id)
                   .map { |go| { id: go.id, name: go.name, short_name: go.short_name } }
    end

    def league_class_options
      scope_rows.distinct.pluck(:league_class_id).compact_blank
                .map { |id| { id:, name: Setting.league_class(id).presence || id } }
                .sort_by { |entry| League.class_rank(entry[:id]) }
    end

    def league_options
      ids = scope_rows.distinct.pluck(:league_id)
      League.unscoped.where(id: ids).pluck(:id, :name, :season_id, :league_class_id)
            .map { |id, name, season_id, league_class_id| { id:, name:, season_id:, league_class_id: } }
            .sort_by { |league| [-league[:season_id].to_i, league[:name].to_s] }
    end

    def team_options
      ids = scope_rows.distinct.pluck(:team_id)
      Team.where(id: ids).order(:name).pluck(:id, :name).map { |id, name| { id:, name: } }
    end

    def club_options
      ids = scope_rows.distinct.pluck(:club_id)
      Club.where(id: ids).order(:name).pluck(:id, :name).map { |id, name| { id:, name: } }
    end
  end
end
