# Schiri-Selfservice für die eigene Vereins-Ausschlussliste. Die Liste selbst
# kommt mit dem Profil (RefereeProfileController#show), hier laufen nur die
# Anträge und die Vereinsauswahl.
class RefereeClubExclusionsController < ApplicationController
  include RefereeClubExclusionPresenter

  before_action :authenticate_user
  before_action :require_referee_account

  # GET /api/v2/referee/clubs
  # Vereinsliste für die Auswahl im Antrag. Bewusst ein eigener, nur für
  # Schiri-Konten erreichbarer Endpoint – admin/clubs ist rollengeschützt und
  # game_operations/:id/clubs liefert nur einen Spielbetrieb.
  def clubs
    render json: active_clubs_json
  end

  # POST /api/v2/referee/club_exclusions/requests
  def create
    exclusion_request = RefereeClubExclusionRequest.new(
      referee: @referee,
      club_id: request_params[:club_id],
      kind: request_params[:kind],
      reason: request_params[:reason]
    )

    unless exclusion_request.save
      return render json: { errors: exclusion_request.errors.full_messages }, status: :unprocessable_entity
    end

    RefereeMailer.club_exclusion_requested(exclusion_request).deliver_later
    render json: payload, status: :created
  end

  # DELETE /api/v2/referee/club_exclusions/requests/:id
  def destroy
    exclusion_request = @referee.referee_club_exclusion_requests.find(params[:id])

    unless exclusion_request.withdraw!
      return render json: { error: 'Der Antrag wurde bereits entschieden.' }, status: :unprocessable_entity
    end

    render json: payload
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private

  def require_referee_account
    @referee = current_user.referee
    head :forbidden unless @referee
  end

  def request_params
    params.require(:exclusion_request).permit(:club_id, :kind, :reason)
  end

  def payload
    @referee.reload
    {
      club_exclusions: club_exclusions_json(@referee),
      club_exclusion_requests: club_exclusion_requests_json(@referee)
    }
  end
end
