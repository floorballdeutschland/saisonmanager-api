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

    # Ungültige Filterangabe – wird als 422 mit Klartext beantwortet, statt den
    # Cast-Fehler als 500 aus Postgres durchschlagen zu lassen.
    class FilterError < StandardError; end

    rescue_from FilterError do |e|
      render json: { message: e.message }, status: :unprocessable_entity
    end

    # GET /api/v2/admin/game_days/report_overview
    #
    # Immer nur die laufende Saison: Die Übersicht ist ein Arbeitsmittel für den
    # aktuellen Spielbetrieb, abgeschlossene Saisons werden hier nicht geprüft.
    # Filter: game_operation_id, league_id, date_from, date_to (JJJJ-MM-TT).
    def report_overview
      scope = filtered_scope
      games = scope.limit(MAX_ROWS + 1).to_a
      truncated = games.size > MAX_ROWS
      # Sortiert wird absteigend, damit beim Deckeln die ältesten Spieltage
      # wegfallen und nicht die zuletzt gespielten – genau die will die SBK sehen.
      games = games.first(MAX_ROWS) if truncated

      editor_names = editor_names_for(games)

      render json: {
        truncated:,
        games: games.filter_map { |game| safe_game_row(game, editor_names) }
      }
    end

    private

    # Eine einzelne kaputte Altlast (heterogene JSONB-Spalten, Alt-Importe) darf
    # nicht die komplette Übersicht auf 500 setzen. Die Zeile wird stattdessen
    # als fehlerhaft markiert ausgeliefert und der Fall an Sentry gemeldet.
    def safe_game_row(game, editor_names)
      game_row(game, editor_names)
    rescue StandardError => e
      Sentry.capture_exception(e, extra: { game_id: game.id, endpoint: 'admin/game_days#report_overview' })
      {
        id: game.id,
        game_number: game.game_number,
        game_day_id: game.game_day_id,
        row_error: 'Diese Zeile konnte nicht vollständig geladen werden.'
      }
    end

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
        :home_team, :guest_team, :game_referee_report, :proceeding_proposal,
        { game_scan: :uploaded_by },
        game_day: [{ league: { game_operation: :state_association } }, :arena, :club]
      )

      go_ids = scope_go_ids
      scope = scope.where(leagues: { game_operation_id: go_ids }) if go_ids
      # Fest auf die laufende Saison – bewusst nicht über einen Parameter
      # steuerbar, damit Altsaisons hier gar nicht erst auftauchen können.
      scope = scope.where(leagues: { season_id: Setting.current_season_id })
      if params[:game_operation_id].present?
        scope = scope.where(leagues: { game_operation_id: filter_integer(:game_operation_id) })
      end
      scope = scope.where(game_days: { league_id: filter_integer(:league_id) }) if params[:league_id].present?

      # game_days.date ist eine Textspalte – Vergleiche müssen über TO_DATE laufen.
      # NULLIF fängt die leeren Datumsstrings des Altbestands ab (TO_DATE('') liefert
      # sonst ein BC-Datum, das jeden Von-Filter unterläuft).
      if (from = filter_date(:date_from))
        scope = scope.where("TO_DATE(NULLIF(game_days.date, ''), 'YYYY-MM-DD') >= ?", from)
      end
      if (to = filter_date(:date_to))
        scope = scope.where("TO_DATE(NULLIF(game_days.date, ''), 'YYYY-MM-DD') <= ?", to)
      end

      scope.order(Arel.sql(GAME_ORDER))
    end

    # Absteigend nach Spieltag, damit die zuletzt gespielten Spiele oben stehen und
    # beim Deckeln (MAX_ROWS) der alte Bestand wegfällt, nicht der aktuelle.
    #
    # game_number ist Text und enthält auch nicht-numerische Werte („HF1", „FIN",
    # „Pl. 3" in K.-o.-Runden). Ein blanker ::integer-Cast lässt Postgres die ganze
    # Abfrage abbrechen, deshalb wird nur der rein numerische Fall gecastet.
    # start_time ist ebenfalls Text; '' muss wie NULL ans Ende, nicht an den Anfang.
    GAME_ORDER = <<~SQL.squish.freeze
      game_days.date DESC,
      NULLIF(games.start_time, '') ASC NULLS LAST,
      CASE WHEN games.game_number ~ '^[0-9]+$' THEN games.game_number::integer END ASC NULLS LAST
    SQL

    def filter_integer(key)
      value = params[key].to_s
      raise FilterError, "#{key} muss eine Zahl sein." unless value.match?(/\A\d+\z/)

      value.to_i
    end

    # Datumsfilter streng prüfen: ein unvalidierter Wert schlägt sonst als
    # Postgres-Cast-Fehler (500) durch statt als verständliche Meldung.
    def filter_date(key)
      return nil if params[key].blank?

      Date.strptime(params[key], '%Y-%m-%d')
    rescue Date::Error
      raise FilterError, "#{key} muss im Format JJJJ-MM-TT angegeben werden."
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

        scan_required: game.state_association&.effective_scan_required || false,
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
    # fehlt oder unlesbar ist (Altbestand mit leeren/kaputten Datumsstrings).
    #
    # Bewusst strptime statt Date.parse: Date.parse ist nachsichtig und liefert für
    # Bruchstücke wie "31" klaglos ein Datum des laufenden Monats – also eine
    # falsche Tagesdifferenz statt nil. strptime interpretiert das Datum zudem
    # genau wie der TO_DATE-Filter oben.
    def days_after(game_day_date, uploaded_at)
      raw = game_day_date.to_s
      return nil if raw.blank?

      (uploaded_at.to_date - Date.strptime(raw, '%Y-%m-%d')).to_i
    rescue Date::Error
      nil
    end

    # Zählt verneinte Checklisten-Punkte. Die Schreibpfade erzwingen zwar echte
    # Booleans, der JSONB-Altbestand ist aber nicht garantiert ein Array aus
    # Hashes – ohne die Formprüfung würde eine abweichende Form die ganze
    # Übersicht auf 500 setzen.
    def negative_answer_count(answers)
      return 0 unless answers.is_a?(Array)

      answers.count { |a| a.is_a?(Hash) && [false, 'false'].include?(a['answer']) }
    end

    def flags(game)
      # Die drei `missing_*` sind Hinweise auf fehlende Nacharbeit, keine
      # Tatsachenaussagen: Zuschauerzahl, Unterschriften und zweiter
      # Schiedsrichter stehen erst am Spieltag fest. Für ein Spiel, das noch
      # aussteht, wären sie zwangsläufig alle gesetzt – die halbe Restsaison
      # trüge dann eine Auffälligkeit, und die Markierung verlöre ihren Wert.
      #
      # Die übrigen Flags bleiben unberührt: protest, forfait,
      # special_event_string und Strafen kann nur setzen, wer den Bericht
      # führt, ein ausstehendes Spiel trägt sie also ohnehin nicht.
      pending = upcoming?(game)

      {
        protest: game.protest || false,
        forfait: game.forfait.to_i.positive?,
        special_event_string: game.special_event_string.presence,
        severe_penalty_count: severe_penalty_count(game),
        # nil? statt blank?: 0 Zuschauer ist eine gültige Angabe, aber `0.blank?`
        # ist in Rails false – blank? würde die fehlende Angabe also nie melden.
        missing_audience: !pending && game.audience.nil?,
        missing_signatures: !pending && !signatures_complete?(game),
        missing_referee2: !pending && game.referee2_string.blank?
      }
    end

    # Spiel steht noch aus: nicht begonnen UND Spieltag in der Zukunft.
    #
    # Beide Bedingungen zusammen. Nur „nicht begonnen" würde einen liegen
    # gebliebenen Bericht von vorletzter Woche mit ausblenden – genau den, den
    # die SBK sehen muss. Nur „Datum in der Zukunft" würde einen vorab
    # geführten Bericht nicht mehr prüfen.
    #
    # Verglichen wird in Europe/Berlin: Der Server läuft in UTC, und `Date.today`
    # hinge dort in den ersten Stunden nach Mitternacht noch am Vortag – der
    # laufende Spieltag zählte dann als Zukunft.
    def upcoming?(game)
      return false unless game.game_status.blank? || game.game_status == 'pregame'

      date = game_day_date(game.game_day)
      date.present? && date > Time.find_zone!('Europe/Berlin').today
    end

    # game_days.date ist eine Textspalte und im Altbestand auch mal leer oder
    # unlesbar. strptime statt Date.parse aus demselben Grund wie in `days_after`.
    def game_day_date(game_day)
      raw = game_day&.date.to_s
      return nil if raw.blank?

      Date.strptime(raw, '%Y-%m-%d')
    rescue Date::Error
      nil
    end

    # Zählt Strafen ab 5 Minuten inkl. Matchstrafen.
    #
    # Bevorzugt das ins Event eingefrorene Label (katalogunabhängig) und greift nur
    # für Alt-Ereignisse ohne Label auf den Katalog zurück. Game#penalty_mapping
    # würde dafür je Ereignis `Setting.current` lesen; das geht in Produktion über
    # den :memory_store, der bei jedem Treffer den kompletten Settings-Datensatz
    # kopiert. Bei bis zu 2000 Spielen mit je etlichen Strafen wäre das der
    # teuerste Teil der Abfrage – daher der Katalog einmal je Request.
    def severe_penalty_count(game)
      events = game.events
      return 0 unless events.is_a?(Array)

      events.count do |event|
        next false unless event.is_a?(Hash)
        next false if event['penalty_id'].blank?

        mapping = event['penalty_mapping'].presence ||
                  penalties_catalog.dig(event['penalty_id'].to_s, 'mapping')
        SEVERE_PENALTY_MAPPINGS.include?(mapping.to_s)
      end
    end

    def penalties_catalog
      @penalties_catalog ||= Setting.current.penalties || {}
    end

    def signatures_complete?(game)
      game.referee1_signed && game.time_keeper_signed && game.record_keeper_signed &&
        game.home_captain_signed && game.guest_captain_signed
    end
  end
end
