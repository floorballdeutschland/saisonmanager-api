module Admin
  class StateAssociationReleasesController < ApplicationController
    before_action :authorize_admin!
    before_action :set_state_association

    # POST /api/v2/admin/state_associations/:state_association_id/releases
    def create
      release = @state_association.releases.new(
        recipient_game_operation_id: params[:recipient_game_operation_id],
        season_id: Setting.current_season_id
      )
      if release.save
        render json: release_hash(release), status: :created
      else
        render json: { errors: release.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/state_associations/:state_association_id/releases/:id
    def destroy
      release = @state_association.releases.find(params[:id])
      release.destroy
      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Freigabe nicht gefunden' }, status: :not_found
    end

    private

    def set_state_association
      @state_association = StateAssociation.find(params[:state_association_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Landesverband nicht gefunden' }, status: :not_found
    end

    def release_hash(release)
      {
        id: release.id,
        recipient_game_operation_id: release.recipient_game_operation_id,
        recipient_game_operation_name: release.recipient_game_operation.name
      }
    end

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
