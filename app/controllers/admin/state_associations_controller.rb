module Admin
  class StateAssociationsController < ApplicationController
    before_action :authorize_sa_access!
    before_action :authorize_admin!, only: %i[create update destroy]
    before_action :set_state_association, only: %i[show update destroy]

    # GET /api/v2/admin/state_associations
    def index
      ph = current_user.permission_hash
      if ph[:admin].present?
        render json: StateAssociation.with_attached_logo.order(:name).map(&:short_hash)
      else
        render json: scoped_state_associations.with_attached_logo.order(:name).map(&:short_hash)
      end
    end

    # GET /api/v2/admin/state_associations/:id
    def show
      ph = current_user.permission_hash
      unless ph[:admin].present? || scoped_state_associations.exists?(@state_association.id)
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      render json: @state_association.full_hash
    end

    # POST /api/v2/admin/state_associations
    def create
      sa = StateAssociation.new(state_association_params)
      if sa.save
        render json: sa.full_hash, status: :created
      else
        render json: { errors: sa.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/state_associations/:id
    def update
      if @state_association.update(state_association_params)
        render json: @state_association.full_hash
      else
        render json: { errors: @state_association.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/state_associations/:id
    def destroy
      @state_association.destroy
      head :no_content
    end

    private

    def set_state_association
      @state_association = StateAssociation.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Landesverband nicht gefunden' }, status: :not_found
    end

    def state_association_params
      params.require(:state_association).permit(:name, :short_name, :vsk_email, :sbk_email, :scan_required,
                                                :parent_id, :express_license_enabled, :logo)
    end

    def scoped_state_associations
      ph = current_user.permission_hash
      go_ids = ((ph[:sbk] || []) + (ph[:rsk] || [])).reject { |id| id.zero? }.uniq
      sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact
      StateAssociation.where(id: sa_ids)
    end

    def authorize_sa_access!
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if ph[:sbk].present? || ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
