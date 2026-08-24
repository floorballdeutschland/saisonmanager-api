module Admin
  # Anträge der Schiedsrichter auf Korrektur ihrer Stammdaten. Entschieden von
  # der RSK des Landesverbands, in dem der Verein des Schiris liegt; ein global
  # gescoptes (FD-)Konto sieht alle.
  #
  # Bewusst an der RSK und nicht an der Ansetzer-Rolle: Es geht um Stammdaten
  # und nicht um Ansetzbarkeit. Die Vereins-Ausschlüsse nebenan liegen genau
  # deshalb umgekehrt.
  class RefereeChangeRequestsController < ApplicationController
    include RefereeScoping

    before_action :authenticate_user
    before_action :authorize_rsk!
    before_action :set_request, only: %i[approve reject]

    # GET /api/v2/admin/referee_change_requests?status=pending
    def index
      scope = RefereeChangeRequest.where(referee_id: permitted_referee_ids)
                                  .includes(:new_club, referee: :club)
      scope = scope.where(status: params[:status]) if params[:status].present?

      render json: scope.order(created_at: :desc).map { |r| request_json(r) }
    end

    # POST /api/v2/admin/referee_change_requests/:id/approve
    def approve
      return already_decided unless @change_request.approve!(current_user.id, params[:decision_note])

      notify_referee(@change_request)
      render json: request_json(@change_request.reload)
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    end

    # POST /api/v2/admin/referee_change_requests/:id/reject
    def reject
      note = params[:decision_note].to_s.strip
      if note.blank?
        return render json: { errors: ['Bitte eine kurze Begründung für die Ablehnung angeben.'] },
                      status: :unprocessable_entity
      end

      return already_decided unless @change_request.reject!(current_user.id, note)

      notify_referee(@change_request)
      render json: request_json(@change_request.reload)
    end

    private

    # Stammdaten pflegt das Schiedsrichterwesen: Admin oder RSK. Die
    # Ansetzer-Rolle bleibt außen vor, auch wenn sie die Schiris sehen darf.
    def authorize_rsk!
      ph = permission_hash
      return if ph[:admin].present? || ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Wie RefereeScoping#scope_to_permitted_referees, aber ohne den VM- und den
    # Ansetzer-Zweig: Entscheiden darf nur die RSK des zuständigen Verbands.
    def permitted_referee_ids
      ph = permission_hash
      return Referee.all.select(:id) if ph[:admin].present? || ph[:rsk].include?(0)

      go_ids = ph[:rsk].reject(&:zero?)
      Referee.where(club_id: lv_club_ids(go_ids))
             .or(Referee.where(game_operation_id: go_ids))
             .select(:id)
    end

    def set_request
      @change_request = RefereeChangeRequest.where(referee_id: permitted_referee_ids).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def already_decided
      render json: { errors: ['Der Antrag wurde bereits entschieden.'] }, status: :unprocessable_entity
    end

    def notify_referee(change_request)
      return if change_request.referee.email.blank?

      RefereeMailer.change_decision(change_request).deliver_later
    end

    def request_json(change_request)
      referee = change_request.referee
      change_request.as_json.merge(
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
