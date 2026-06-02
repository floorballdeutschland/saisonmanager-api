module Admin
  class PlayerChangeRequestsController < ApplicationController
    def index
      ph = current_user.permission_hash
      requests = if ph[:admin].present?
                   PlayerChangeRequest.all
                 elsif ph[:sbk].present?
                   PlayerChangeRequest.for_go(ph[:sbk])
                 elsif ph[:vm].present?
                   PlayerChangeRequest.for_club(ph[:vm])
                 else
                   return render json: [], status: :ok
                 end

      render json: requests.order(created_at: :desc).includes(:player, :club)
    end

    def create
      ph = current_user.permission_hash
      club_id = params[:club_id].to_i

      unless ph[:admin].present? || ph[:vm]&.include?(club_id)
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

      player = Player.find_by(id: params[:player_id])
      return render json: { error: 'Spieler nicht gefunden' }, status: :not_found unless player

      request = PlayerChangeRequest.new(
        player: player,
        club_id: club_id,
        correction_type: params[:correction_type],
        new_value: params[:new_value].presence,
        status: 'pending',
        requested_by_user_id: current_user.id
      )

      if request.save
        render json: request, status: :created
      else
        render json: { errors: request.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def approve
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

      request = PlayerChangeRequest.find(params[:id])
      unless ph[:admin].present? || sbk_can_access_request?(ph, request)
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end
      return render json: { error: 'Antrag nicht mehr ausstehend' }, status: :unprocessable_entity unless request.status == 'pending'

      PlayerChangeRequest.transaction do
        request.apply!(current_user.id)
      end

      render json: request
    rescue ActiveRecord::RecordInvalid => e
      render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
    end

    def reject
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end

      request = PlayerChangeRequest.find(params[:id])
      unless ph[:admin].present? || sbk_can_access_request?(ph, request)
        return render json: { error: 'Keine Berechtigung' }, status: :forbidden
      end
      return render json: { error: 'Antrag nicht mehr ausstehend' }, status: :unprocessable_entity unless request.status == 'pending'

      if request.update(status: 'rejected', rejection_reason: params[:rejection_reason], reviewed_by_user_id: current_user.id)
        render json: request
      else
        render json: { errors: request.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    # Analog zu PlayerChangeRequest.for_go: Ein nicht-globaler SBK darf nur
    # Anträge entscheiden, deren Verein in seinem game_operation-Scope liegt.
    def sbk_can_access_request?(perm_hash, request)
      return false unless perm_hash[:sbk].present?
      return true if perm_hash[:sbk].include?(0)

      club = Club.find_by(id: request.club_id)
      club.present? && perm_hash[:sbk].include?(club.main_game_operation_id)
    end
  end
end
