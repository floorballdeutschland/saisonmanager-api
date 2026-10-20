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
    def create
      comment = params[:comment].to_s.strip.presence
      if comment && comment.length > COMMENT_MAX_LENGTH
        return render json: { message: "Der Kommentar darf höchstens #{COMMENT_MAX_LENGTH} Zeichen lang sein." },
                      status: :unprocessable_entity
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
      @game = Game.includes(game_day: :league).find_by(id: params[:game_id])
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

    def review_payload
      reviewer = @game.report_reviewed_by_user_id && User.find_by(id: @game.report_reviewed_by_user_id)
      {
        id: @game.id,
        report_reviewed_at: @game.report_reviewed_at,
        report_reviewed_by_name: reviewer&.fullname&.strip.presence,
        report_review_comment: @game.report_review_comment,
        report_changed_since_review: false
      }
    end
  end
end
