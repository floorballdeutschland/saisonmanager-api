module Admin
  class StateAssociationReleasesController < ApplicationController
    include StateAssociationWritable

    # Freigaben gehören zur Selbstverwaltung des eigenen Landesverbands:
    # globaler Admin überall, SBK auf seinem gescopten LV.
    before_action :set_state_association
    before_action :authorize_state_association_write!

    # GET /api/v2/admin/state_associations/:state_association_id/releases/candidates
    # Mögliche Empfänger-Sportverbünde für eine Freigabe: alle Sportverbünde
    # außer den eigenen des freigebenden Landesverbands (eine Freigabe an den
    # eigenen Verbund ergibt keinen Sinn). Das Ausfiltern bereits bestehender
    # Freigaben übernimmt das Frontend.
    def candidates
      own_go_ids = GameOperation.where(state_association_id: @state_association.id).pluck(:id)
      gos = GameOperation.where.not(id: own_go_ids).order(:name)
      render json: gos.map { |go| { id: go.id, name: go.name } }
    end

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
        recipient_game_operation_name: release.recipient_game_operation.name,
        season_id: release.season_id
      }
    end
  end
end
