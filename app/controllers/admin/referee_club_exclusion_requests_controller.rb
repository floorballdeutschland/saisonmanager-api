module Admin
  # Anträge der Schiedsrichter auf Aufnahme oder Streichung eines Vereins in
  # ihrer Ausschlussliste. Entschieden ausschließlich von der bundesweiten
  # Ansetzung von Floorball Deutschland (authorize_national_assigner!), an die
  # auch die Antragsmail geht. Das Scoping über RefereeScoping bleibt stehen,
  # greift für diese Rollen aber nicht mehr ein.
  class RefereeClubExclusionRequestsController < ApplicationController
    include RefereeScoping

    before_action :authenticate_user
    before_action :authorize_national_assigner!
    before_action :set_request, only: %i[approve reject]

    # GET /api/v2/admin/referee_club_exclusion_requests?status=pending
    def index
      scope = RefereeClubExclusionRequest.where(referee_id: permitted_referee_ids)
                                         .includes(:club, referee: :club)
      scope = scope.where(status: params[:status]) if params[:status].present?

      render json: scope.order(created_at: :desc).map { |r| request_json(r) }
    end

    # POST /api/v2/admin/referee_club_exclusion_requests/:id/approve
    def approve
      return already_decided unless @exclusion_request.approve!(current_user.id, params[:decision_note])

      notify_referee(@exclusion_request)
      render json: request_json(@exclusion_request.reload)
    end

    # POST /api/v2/admin/referee_club_exclusion_requests/:id/reject
    def reject
      note = params[:decision_note].to_s.strip
      if note.blank?
        return render json: { errors: ['Bitte eine kurze Begründung für die Ablehnung angeben.'] },
                      status: :unprocessable_entity
      end

      return already_decided unless @exclusion_request.reject!(current_user.id, note)

      notify_referee(@exclusion_request)
      render json: request_json(@exclusion_request.reload)
    end

    private

    def permitted_referee_ids
      scope_to_permitted_referees(Referee.all).select(:id)
    end

    def set_request
      @exclusion_request = RefereeClubExclusionRequest.where(referee_id: permitted_referee_ids)
                                                      .find(params[:id])
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def already_decided
      render json: { errors: ['Der Antrag wurde bereits entschieden.'] }, status: :unprocessable_entity
    end

    def notify_referee(exclusion_request)
      return if exclusion_request.referee.email.blank?

      RefereeMailer.club_exclusion_decision(exclusion_request).deliver_later
    end

    def request_json(exclusion_request)
      referee = exclusion_request.referee
      exclusion_request.as_json.merge(
        referee: {
          id: referee.id,
          lizenznummer_display: referee.lizenznummer_display,
          vorname: referee.vorname,
          nachname: referee.nachname,
          club_name: referee.club&.name
        }
      )
    end
  end
end
