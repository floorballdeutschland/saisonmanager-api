module Admin
  class RefereeQualificationTypesController < ApplicationController
    before_action :authorize_rsk!
    before_action :set_type, only: %i[update destroy]

    # GET /api/v2/admin/referee_qualification_types
    def index
      types = RefereeQualificationType.order(:name)
      render json: types.map { |t| type_json(t) }
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

    def authorize_rsk!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:rsk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def type_json(type)
      {
        id: type.id,
        name: type.name,
        short_name: type.short_name,
        active: type.active,
        usage_count: type.referee_qualifications.count
      }
    end
  end
end
