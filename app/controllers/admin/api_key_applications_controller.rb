module Admin
  # Anträge Außenstehender auf einen API-Zugang. Entschieden wird ausschließlich
  # von der Administration, weil ein Key verbandsübergreifend alle öffentlichen
  # Daten liefert.
  #
  # Eine Genehmigung erzeugt noch keinen Key: Sie stellt einen Einmal-Link aus,
  # über den der Antragsteller ihn abholt (Begründung im Modell).
  class ApiKeyApplicationsController < ApplicationController
    before_action :authorize_admin!
    before_action :set_application, only: %i[approve reject resend_reveal]

    # GET /api/v2/admin/api_key_applications?status=pending
    def index
      scope = ApiKeyApplication.all
      scope = scope.where(status: params[:status]) if params[:status].present?

      render json: scope.order(created_at: :desc).as_json
    end

    # POST /api/v2/admin/api_key_applications/:id/approve
    def approve
      token = @application.approve!(current_user.id, params[:decision_note])
      return already_decided unless token

      ApiKeyApplicationMailer.approved(@application, token).deliver_later
      render json: @application.reload.as_json
    end

    # POST /api/v2/admin/api_key_applications/:id/reject
    def reject
      note = params[:decision_note].to_s.strip
      if note.blank?
        return render json: { errors: ['Bitte eine kurze Begründung für die Ablehnung angeben.'] },
                      status: :unprocessable_entity
      end

      return already_decided unless @application.reject!(current_user.id, note)

      ApiKeyApplicationMailer.rejected(@application).deliver_later
      render json: @application.reload.as_json
    end

    # POST /api/v2/admin/api_key_applications/:id/resend_reveal
    # Neuer Abhol-Link, wenn der alte abgelaufen ist oder nicht angekommen ist.
    def resend_reveal
      token = @application.issue_new_reveal_token!
      unless token
        return render json: { errors: ['Für diesen Antrag lässt sich kein neuer Abhol-Link ausstellen.'] },
                      status: :unprocessable_entity
      end

      ApiKeyApplicationMailer.approved(@application, token).deliver_later
      render json: @application.reload.as_json
    end

    private

    def set_application
      @application = ApiKeyApplication.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Antrag nicht gefunden' }, status: :not_found
    end

    def already_decided
      render json: { errors: ['Der Antrag wurde bereits entschieden.'] }, status: :unprocessable_entity
    end

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
