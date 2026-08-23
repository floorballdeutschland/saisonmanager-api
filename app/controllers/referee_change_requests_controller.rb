# Selfservice der Schiedsrichter für Korrekturen an den eigenen Stammdaten
# (Vorname, Nachname, Geburtsdatum, Verein). Die laufenden Anträge kommen mit
# dem Profil (RefereeProfileController#show), hier laufen nur Anlegen und
# Zurückziehen.
class RefereeChangeRequestsController < ApplicationController
  include RefereeChangeRequestPresenter

  before_action :authenticate_user
  before_action :require_referee_account

  # POST /api/v2/referee/change_requests
  def create
    change_request = RefereeChangeRequest.new(
      referee: @referee,
      correction_type: request_params[:correction_type],
      new_value: request_params[:new_value].presence,
      new_club_id: request_params[:new_club_id].presence,
      reason: request_params[:reason].presence,
      requested_by_user_id: current_user.id
    )

    unless change_request.save
      return render json: { errors: change_request.errors.full_messages }, status: :unprocessable_entity
    end

    RefereeMailer.change_requested(change_request).deliver_later
    render json: payload, status: :created
  end

  # DELETE /api/v2/referee/change_requests/:id
  def destroy
    change_request = @referee.referee_change_requests.find(params[:id])

    unless change_request.withdraw!
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
    params.require(:change_request).permit(:correction_type, :new_value, :new_club_id, :reason)
  end

  def payload
    @referee.reload
    { change_requests: change_requests_json(@referee) }
  end
end
