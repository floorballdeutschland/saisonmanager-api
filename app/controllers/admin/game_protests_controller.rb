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

    before_action :load_game_and_authorize!

    # GET /api/v2/admin/games/:game_id/protests/:party/file
    def file
      protest = @game.game_protests.find_by(party: params[:party])
      unless protest&.file&.attached?
        return render json: { message: 'Zu diesem Protest liegt kein Formular vor.' }, status: :not_found
      end

      render json: { url: rails_blob_url(protest.file, disposition: 'inline'), filename: protest.file.filename.to_s }
    end

    # POST /api/v2/admin/games/:game_id/protests/:party/resend  (optional `email`)
    #
    # Verschickt einen neuen Upload-Link, der alte wird ungültig. Mit `email`
    # geht er an genau diese Adresse (für den Fall, dass keine hinterlegt war
    # oder die Partei eine andere nennt), sonst an die aktuell ermittelten
    # Adressen der Partei. 422 statt 403/404 bei fachlichen Absagen: Die
    # Meldung soll in der Arbeitsansicht stehen, ein 403 leitet im Frontend um.
    def resend
      protest = @game.game_protests.find_by(party: params[:party])
      error = resend_error(protest)
      return render json: { message: error }, status: :unprocessable_entity if error

      recipients, error = resend_recipients(protest)
      return render json: { message: error }, status: :unprocessable_entity if error

      token = protest.regenerate_token!(recipients:)
      GameMailer.protest_upload_invitation(protest, token).deliver_later
      render json: GameProtest.overview_row(@game, protest.party, protest)
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

    def resend_error(protest)
      return 'Für diese Partei gibt es noch keinen Upload-Link. Er geht beim Abschluss des Spielberichts raus.' if protest.nil?
      return 'Diese Partei hat ihr Protestformular bereits hochgeladen.' if protest.submitted?

      nil
    end

    def resend_recipients(protest)
      if params[:email].present?
        emails = TeamContactRecipients.deliverable([params[:email].to_s])
        return [nil, 'Bitte gib eine gültige E-Mail-Adresse an.'] if emails.size != 1

        return [emails, nil]
      end

      emails = GameProtestInviter.new(@game).recipients_for(protest.party)
      return [nil, 'Für diese Partei ist keine Adresse hinterlegt. Gib eine E-Mail-Adresse an.'] if emails.empty?

      [emails, nil]
    end
  end
end
