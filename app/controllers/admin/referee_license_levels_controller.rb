module Admin
  class RefereeLicenseLevelsController < ApplicationController
    before_action :authorize_read!, only: %i[index]
    before_action :authorize_write!, only: %i[create update destroy]
    before_action :set_level, only: %i[update destroy]

    # GET /api/v2/admin/referee_license_levels
    def index
      levels = RefereeLicenseLevel.ordered
      render json: levels.map { |l| level_json(l) }
    end

    # POST /api/v2/admin/referee_license_levels
    def create
      level = RefereeLicenseLevel.new(level_params)
      if level.save
        render json: level_json(level), status: :created
      else
        render json: { errors: level.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referee_license_levels/:id
    def update
      if @level.update(level_params)
        render json: level_json(@level)
      else
        render json: { errors: @level.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referee_license_levels/:id
    def destroy
      if @level.usage_count.positive?
        render json: { error: 'Lizenzstufe wird noch verwendet und kann nicht gelöscht werden.' },
               status: :unprocessable_entity
      else
        @level.destroy
        head :no_content
      end
    end

    private

    def set_level
      @level = RefereeLicenseLevel.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Lizenzstufe nicht gefunden' }, status: :not_found
    end

    def level_params
      params.require(:referee_license_level).permit(:name, :active, :position, :validity_years)
    end

    def authorize_read!
      ph = current_user.permission_hash
      # Ansetzer haben Lesezugriff auf die Schiedsrichterdaten (Schiri-Bearbeiten-Ansicht
      # lädt die Lizenzstufen mit), daher hier ebenfalls erlaubt.
      return if ph[:admin].present? || ph[:rsk].present? || ph[:sbk].present? || ph[:ansetzer].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def authorize_write!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def level_json(level)
      {
        id: level.id,
        name: level.name,
        active: level.active,
        position: level.position,
        validity_years: level.validity_years,
        usage_count: level.usage_count
      }
    end
  end
end
