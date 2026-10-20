module Admin
  # Erledigt-Vermerk der SBK an einem Spielbericht in der Arbeitsansicht
  # „Spielberichte", optional mit Kommentar. Rein ein Arbeitsvermerk: Er ändert
  # weder Status noch Wertung des Spiels und ist jederzeit zurückzunehmen.
  #
  # Dürfen darf es, wer die Zeile in der Übersicht sieht: Admin oder SBK des
  # Spielbetriebs des Spiels (GameReportReviewScope). Ein VM oder TM sieht die
  # Arbeitsansicht nicht und kann hier auch nichts abhaken.
  class GameReportReviewsController < ApplicationController
    include GameReportReviewScope

    COMMENT_MAX_LENGTH = 2000

    before_action :load_game_and_authorize!

    # POST /api/v2/admin/games/:game_id/report_review
    # Setzt den Vermerk neu, auch wenn schon einer steht: Wer erneut abhakt,
    # hat den aktuellen Stand gesehen, und sein Kommentar ersetzt den alten.
    #
    # seen_until: der last_change_at der Zeile, die die SBK vor sich hatte. Ist
    # seitdem etwas Neues eingegangen (ein Einspruch, ein ersetzter Bericht),
    # würde der Vermerk etwas abhaken, das niemand gesehen hat. Dann 409.
    # Fehlt der Wert (älteres Frontend), wird wie bisher gespeichert.
    def create
      comment = params[:comment].to_s.strip.presence
      if comment && comment.length > COMMENT_MAX_LENGTH
        return render json: { message: "Der Kommentar darf höchstens #{COMMENT_MAX_LENGTH} Zeichen lang sein." },
                      status: :unprocessable_entity
      end

      if stale_view?
        return render json: { message: 'Der Bericht hat sich seit dem Laden geändert. Bitte lade die Übersicht neu ' \
                                       'und prüfe den aktuellen Stand, bevor du ihn als erledigt markierst.' },
                      status: :conflict
      end

      write_review(report_reviewed_at: Time.current, report_reviewed_by_user_id: current_user.id,
                   report_review_comment: comment)
      render json: review_payload
    end

    # DELETE /api/v2/admin/games/:game_id/report_review
    def destroy
      write_review(report_reviewed_at: nil, report_reviewed_by_user_id: nil, report_review_comment: nil)
      render json: review_payload
    end

    private

    def load_game_and_authorize!
      @game = Game.includes(:game_scan, :game_referee_report, :proceeding_proposal, game_day: :league)
                  .find_by(id: params[:game_id])
      return head :not_found if @game.nil?

      ph = current_user.permission_hash
      allowed = (ph[:admin].present? || ph[:sbk].present?) &&
                game_operation_in_scope?(@game.game_day&.league&.game_operation_id)
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless allowed
    end

    # update_columns statt update: Der Vermerk gehört der SBK, nicht dem
    # Spielbericht. Ein normales Speichern liefe durch correct_teams! und
    # flush_league_caches, obwohl sich an Teams und Wertung nichts ändert, und
    # die Übersicht vergleicht record_updated_at mit dem Vermerk
    # (report_changed_since_review). Deshalb bleiben auch record_updated_at
    # und updated_at unberührt.
    def write_review(attributes)
      @game.update_columns(attributes)
    end

    def last_change_at
      @last_change_at ||= GameReportLastChange.for(@game)
    end

    # Auf Millisekunden verglichen: So genau gibt die Übersicht den Zeitpunkt
    # im JSON aus, die Datenbank hält Mikrosekunden. Ohne das Abrunden wäre
    # jeder Vermerk ein Konflikt mit sich selbst.
    def stale_view?
      return false if params[:seen_until].blank? || last_change_at.nil?

      seen_until = Time.zone.parse(params[:seen_until].to_s)
      seen_until.nil? || last_change_at.floor(3) > seen_until
    rescue ArgumentError
      true
    end

    def review_payload
      reviewer = @game.report_reviewed_by_user_id && User.find_by(id: @game.report_reviewed_by_user_id)
      reviewed_at = @game.report_reviewed_at
      {
        id: @game.id,
        report_reviewed_at: reviewed_at,
        report_reviewed_by_name: reviewer&.fullname&.strip.presence,
        report_review_comment: @game.report_review_comment,
        report_changed_since_review: reviewed_at.present? && last_change_at.present? && last_change_at > reviewed_at,
        last_change_at:
      }
    end
  end
end
