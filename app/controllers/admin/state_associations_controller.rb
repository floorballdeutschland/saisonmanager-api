module Admin
  class StateAssociationsController < ApplicationController
    before_action :authorize_sa_access!
    before_action :authorize_admin!, only: %i[create update destroy upload_banner delete_banner]
    before_action :set_state_association, only: %i[show update destroy upload_banner delete_banner]

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

    # POST /api/v2/admin/state_associations/:id/upload_banner
    def upload_banner
      return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity unless params[:banner].present?

      unless params[:banner].content_type == 'image/webp'
        return render json: { message: 'Nur WebP-Dateien erlaubt' }, status: :unprocessable_entity
      end

      if params[:banner].size > 500.kilobytes
        return render json: { message: 'Maximale Dateigröße: 500 KB' }, status: :unprocessable_entity
      end

      begin
        @state_association.banner.attach(params[:banner])
        render json: { banner_url: @state_association.banner_url }
      rescue StandardError => e
        Rails.logger.error("Banner-Upload fehlgeschlagen (StateAssociation #{@state_association.id}): #{e.class}: #{e.message}")
        render json: { message: 'Banner konnte nicht gespeichert werden.' }, status: :internal_server_error
      end
    end

    # DELETE /api/v2/admin/state_associations/:id/banner
    def delete_banner
      begin
        @state_association.banner.purge
        render json: { success: true }
      rescue StandardError => e
        Rails.logger.error("Banner-Löschen fehlgeschlagen (StateAssociation #{@state_association.id}): #{e.class}: #{e.message}")
        render json: { message: 'Banner konnte nicht gelöscht werden.' }, status: :internal_server_error
      end
    end

    private

    def set_state_association
      @state_association = StateAssociation.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Landesverband nicht gefunden' }, status: :not_found
    end

    def state_association_params
      params.require(:state_association).permit(:name, :short_name, :vsk_email, :sbk_email, :scan_required,
                                                :parent_id, :express_license_enabled, :logo, :banner_link_url)
    end

    def scoped_state_associations
      ph = current_user.permission_hash
      go_ids = ((ph[:sbk] || []) + (ph[:rsk] || [])).reject(&:zero?).uniq
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
