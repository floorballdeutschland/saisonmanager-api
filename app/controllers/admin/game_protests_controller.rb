module Admin
  # Protestformulare in der SBK-Arbeitsansicht „Spielberichte". Die Übersicht
  # (GameDaysController#report_overview) liefert nur die Metadaten, die Datei
  # wird erst beim Klick geholt, damit nicht für jede Zeile eine signierte
  # Blob-URL entsteht (wie beim Papierbogen).
  #
  # Dürfen darf es, wer die Zeile sieht: Admin oder SBK des Spielbetriebs
  # (GameReportReviewScope).
  class GameProtestsController < ApplicationController
    include GameReportReviewScope

    # GET /api/v2/admin/games/:game_id/protests/:party/file
    def file
      game = Game.includes(game_day: :league).find_by(id: params[:game_id])
      return head :not_found if game.nil?

      ph = current_user.permission_hash
      allowed = (ph[:admin].present? || ph[:sbk].present?) &&
                game_operation_in_scope?(game.game_day&.league&.game_operation_id)
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless allowed

      protest = game.game_protests.find_by(party: params[:party])
      unless protest&.file&.attached?
        return render json: { message: 'Zu diesem Protest liegt kein Formular vor.' }, status: :not_found
      end

      render json: { url: rails_blob_url(protest.file, disposition: 'inline'), filename: protest.file.filename.to_s }
    end
  end
end
