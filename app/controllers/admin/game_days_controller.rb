module Admin
  # SBK-Arbeitsansicht „Spieltage": alle Spielberichte im eigenen Spielbetriebs-Scope
  # mit Status, Bearbeitungszeitpunkten, dem an die SBK gerichteten Hinweisfeld
  # (games.record_comment), dem Papierspielberichtsbogen sowie Auffälligkeiten und
  # verknüpften Vorgängen (Berichtsformular, Verfahrensvorschlag, Checkliste).
  class GameDaysController < ApplicationController
    before_action :authorize_sbk_access!

    # Straf-Kategorien, die eine SBK-Prüfung nach sich ziehen. Die Schlüssel sind
    # die Mappings aus Setting.penalties (vgl. Game#empty_score); 2-Minuten- und
    # 2+2-Strafen sind bewusst nicht dabei.
    SEVERE_PENALTY_MAPPINGS = %w[
      penalty_5 penalty_10 penalty_ms_tech penalty_ms_full penalty_ms1 penalty_ms2 penalty_ms3
    ].freeze

    # Obergrenze je Abfrage. Die Liste wird komplett ans Frontend geliefert (dort
    # wird gruppiert und paginiert); ohne Deckel könnte ein globaler Admin ohne
    # Filter die gesamte Saison ziehen.
    MAX_ROWS = 2000

    # GET /api/v2/admin/game_days/report_overview
    #
    # Filter: season_id (Default: laufende Saison), game_operation_id, league_id,
    # date_from, date_to (jeweils YYYY-MM-DD).
    def report_overview
      scope = filtered_scope
      games = scope.limit(MAX_ROWS + 1).to_a
      truncated = games.size > MAX_ROWS
      games = games.first(MAX_ROWS) if truncated

      editor_names = editor_names_for(games)

      render json: {
        truncated:,
        games: games.map { |game| game_row(game, editor_names) }
      }
    end

    private

    def authorize_sbk_access!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    # nil = global (Admin oder SBK mit Spielbetrieb 0) -> kein Spielbetriebs-Filter.
    def scope_go_ids
      ph = current_user.permission_hash
      return nil if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)

      [ph[:admin], ph[:sbk]].compact.flatten.map(&:to_i)
    end

    def filtered_scope
      scope = Game.joins(game_day: :league).includes(
        :home_team, :guest_team, :game_scan, :game_referee_report, :proceeding_proposal,
        game_day: [{ league: :game_operation }, :arena, :club]
      )

      go_ids = scope_go_ids
      scope = scope.where(leagues: { game_operation_id: go_ids }) if go_ids
      scope = scope.where(leagues: { season_id: season_id })
      if params[:game_operation_id].present?
        scope = scope.where(leagues: { game_operation_id: params[:game_operation_id] })
      end
      scope = scope.where(game_days: { league_id: params[:league_id] }) if params[:league_id].present?

      # game_days.date ist eine Textspalte – Vergleiche müssen über TO_DATE laufen.
      if params[:date_from].present?
        scope = scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') >= ?", params[:date_from])
      end
      if params[:date_to].present?
        scope = scope.where("TO_DATE(game_days.date, 'YYYY-MM-DD') <= ?", params[:date_to])
      end

      # game_number ist ebenfalls Text – numerisch sortieren, Leerwerte ans Ende.
      scope.order(Arel.sql(
                    "game_days.date ASC, games.start_time ASC NULLS LAST, " \
                    "NULLIF(games.game_number, '')::integer ASC NULLS LAST"
                  ))
    end

    def season_id
      params[:season_id].presence || Setting.current_season_id
    end

    # Namen der zuletzt bearbeitenden Nutzer in einem Query auflösen statt je Zeile.
    def editor_names_for(games)
      ids = games.filter_map(&:record_updated_by).uniq
      return {} if ids.empty?

      User.where(id: ids).pluck(:id, :first_name, :last_name)
          .to_h { |id, first, last| [id, [first, last].join(' ').strip] }
    end

    def game_row(game, editor_names)
      game_day = game.game_day
      league = game_day.league

      {
        id: game.id,
        game_number: game.game_number,
        start_time: game.start_time,
        game_day_id: game_day.id,
        game_day_number: game_day.number,
        date: game_day.date,
        league_id: league&.id,
        league_name: league&.name,
        game_operation_slug: league&.game_operation&.slug,
        arena_name: game_day.arena&.name,
        hosting_club_name: game_day.club&.name,
        home_team: game.home_team_name,
        guest_team: game.guest_team_name,
        result_string: game.result_string,

        game_status: game.game_status,
        record_created_at: game.record_created_at,
        record_updated_at: game.record_updated_at,
        record_updated_by_name: editor_names[game.record_updated_by],
        match_record_closed_at: game.match_record_closed_at,

        # Das an die SBK gerichtete Hinweisfeld aus Schritt 3 des Spielberichts.
        record_comment: game.record_comment.presence,

        scan_required: game.state_association&.scan_required || false,
        scan: scan_hash(game, game_day),
        referee_report: referee_report_hash(game),
        proceeding_proposal: proceeding_proposal_hash(game),
        checklist_negative_count: negative_answer_count(game.checklist_answers),
        checklist_veto_submitted_at: game.checklist_veto_submitted_at,
        checklist_veto_negative_count: negative_answer_count(game.checklist_veto_answers),

        flags: flags(game)
      }
    end

    def scan_hash(game, game_day)
      scan = game.game_scan
      return nil if scan.nil?

      {
        uploaded_at: scan.created_at,
        uploaded_by_name: scan.uploaded_by&.fullname,
        days_after_game_day: days_after(game_day.date, scan.created_at),
        expired: scan.expires_at <= Time.current
      }
    end

    def referee_report_hash(game)
      report = game.game_referee_report
      report && { uploaded_at: report.created_at }
    end

    def proceeding_proposal_hash(game)
      proposal = game.proceeding_proposal
      proposal && { id: proposal.id, status: proposal.status }
    end

    # Abstand zwischen Spieltag und Upload in Tagen. nil, wenn das Spieltagsdatum
    # nicht parsebar ist (Altbestand mit leeren/kaputten Datumsstrings).
    def days_after(game_day_date, uploaded_at)
      date = Date.parse(game_day_date.to_s)
      (uploaded_at.to_date - date).to_i
    rescue ArgumentError, TypeError
      nil
    end

    def negative_answer_count(answers)
      (answers || []).count { |a| a['answer'] == false }
    end

    def flags(game)
      {
        protest: game.protest || false,
        forfait: game.forfait.to_i.positive?,
        special_event_string: game.special_event_string.presence,
        severe_penalty_count: severe_penalty_count(game),
        missing_audience: game.audience.blank?,
        missing_signatures: !signatures_complete?(game),
        missing_referee2: game.referee2_string.blank?
      }
    end

    # Zählt Strafen ab 5 Minuten inkl. Matchstrafen. penalty_mapping bevorzugt das
    # ins Event eingefrorene Label und ist damit unabhängig vom aktuellen Katalog.
    def severe_penalty_count(game)
      (game.events || []).count do |event|
        next false if event['penalty_id'].blank?

        SEVERE_PENALTY_MAPPINGS.include?(game.penalty_mapping(event).to_s)
      end
    end

    def signatures_complete?(game)
      game.referee1_signed && game.time_keeper_signed && game.record_keeper_signed &&
        game.home_captain_signed && game.guest_captain_signed
    end
  end
end
