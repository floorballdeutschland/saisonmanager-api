module Admin
  class ApiKeysController < ApplicationController
    before_action :authorize_admin!
    before_action :set_api_key, only: %i[update destroy]

    # GET /api/v2/admin/api_keys
    def index
      render json: ApiKey.order(created_at: :desc).map(&:short_hash)
    end

    # POST /api/v2/admin/api_keys
    def create
      raw_key, api_key = ApiKey.generate(name: api_key_params[:name])
      if raw_key && api_key.persisted?
        render json: api_key.short_hash.merge(raw_key: raw_key), status: :created
      else
        render json: { errors: api_key.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # PATCH /api/v2/admin/api_keys/:id
    def update
      if @api_key.update(api_key_params.slice(:active))
        render json: @api_key.short_hash
      else
        render json: { errors: @api_key.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/api_keys/:id
    def destroy
      @api_key.destroy
      head :no_content
    end

    private

    def set_api_key
      @api_key = ApiKey.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'API-Key nicht gefunden' }, status: :not_found
    end

    def api_key_params
      params.require(:api_key).permit(:name, :active, :rate_limit, :realtime)
    end

    def authorize_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
