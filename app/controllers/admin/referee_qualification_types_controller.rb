module Admin
  class RefereeQualificationTypesController < ApplicationController
    before_action :authorize_referee_read!, only: %i[index]
    before_action :authorize_admin!, only: %i[create update destroy]
    before_action :set_type, only: %i[update destroy]

    # GET /api/v2/admin/referee_qualification_types
    def index
      types = RefereeQualificationType.order(:name)
      counts = RefereeQualification.group(:referee_qualification_type_id).count
      render json: types.map { |t| type_json(t, usage_count: counts[t.id] || 0) }
    end

    # POST /api/v2/admin/referee_qualification_types
    def create
      type = RefereeQualificationType.new(type_params)
      if type.save
        render json: type_json(type), status: :created
      else
        render json: { errors: type.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PUT /api/v2/admin/referee_qualification_types/:id
    def update
      if @type.update(type_params)
        render json: type_json(@type)
      else
        render json: { errors: @type.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/referee_qualification_types/:id
    def destroy
      if @type.referee_qualifications.exists?
        render json: { error: 'Qualifikationstyp wird noch verwendet und kann nicht gelöscht werden.' },
               status: :unprocessable_entity
      else
        @type.destroy
        head :no_content
      end
    end

    private

    def set_type
      @type = RefereeQualificationType.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Qualifikationstyp nicht gefunden' }, status: :not_found
    end

    def type_params
      params.require(:referee_qualification_type).permit(:name, :short_name, :active)
    end

    def authorize_referee_read!
      ph = current_user.permission_hash
      # Ansetzer haben Lesezugriff auf die Schiedsrichterdaten (Schiri-Bearbeiten-Ansicht
      # lädt die Qualifikationstypen mit), daher hier ebenfalls erlaubt.
      return if ph[:admin].present? || ph[:rsk].present? || ph[:sbk].present? || ph[:ansetzer].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    # Qualifikationstypen sind ein bundesweiter Katalog (steuert u. a. die
    # Coach-Auswahl bei der Schiri-Ansetzung für alle Verbände) – Pflege daher
    # bewusst Admin-only, nicht per LV-RSK.
    def authorize_admin!
      return if current_user.permission_hash[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def type_json(type, usage_count: type.referee_qualifications.count)
      {
        id: type.id,
        name: type.name,
        short_name: type.short_name,
        active: type.active,
        usage_count: usage_count
      }
    end
  end
end
