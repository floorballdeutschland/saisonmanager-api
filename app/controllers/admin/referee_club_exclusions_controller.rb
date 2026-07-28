module Admin
  # Pflege der Vereins-Ausschlussliste eines Schiedsrichters durch die Ansetzung,
  # ohne den Umweg über einen Antrag. Sichtbar am Schiri-Profil.
  class RefereeClubExclusionsController < ApplicationController
    include RefereeScoping
    include RefereeClubExclusionPresenter

    before_action :authenticate_user
    before_action :authorize_assigner!
    before_action :set_referee

    # GET /api/v2/admin/referees/:referee_id/club_exclusions
    def index
      render json: payload
    end

    # POST /api/v2/admin/referees/:referee_id/club_exclusions
    def create
      exclusion = RefereeClubExclusion.new(
        referee: @referee,
        club_id: exclusion_params[:club_id],
        reason: exclusion_params[:reason],
        created_by: current_user.id
      )

      if exclusion.save
        render json: payload, status: :created
      else
        render json: { errors: exclusion.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referees/:referee_id/club_exclusions/:id
    def destroy
      exclusion = @referee.referee_club_exclusions.find(params[:id])
      exclusion.destroy
      render json: payload
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    def set_referee
      @referee = scope_to_permitted_referees(Referee.all).find(params[:referee_id])
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    def exclusion_params
      params.require(:exclusion).permit(:club_id, :reason)
    end

    def payload
      @referee.reload
      {
        club_exclusions: club_exclusions_json(@referee),
        club_exclusion_requests: club_exclusion_requests_json(@referee)
      }
    end
  end
end
