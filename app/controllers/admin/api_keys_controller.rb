module Admin
  class ApiKeysController < ApplicationController
    before_action :authorize_admin!

    def index
      render json: ApiKey.order(created_at: :desc).map(&:short_hash)
    end

    def create
      raw_key, api_key = ApiKey.generate(name: params[:name])
      if api_key.persisted?
        render json: api_key.short_hash.merge(raw_key: raw_key), status: :created
      else
        render json: { errors: api_key.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def update
      api_key = ApiKey.find(params[:id])
      if api_key.update(active: params[:active])
        render json: api_key.short_hash
      else
        render json: { errors: api_key.errors.full_messages }, status: :unprocessable_entity
      end
    end

    def destroy
      ApiKey.find(params[:id]).destroy
      head :no_content
    end

    private

    def authorize_admin!
      ph = current_user.permission_hash
      render json: { error: 'Nicht berechtigt' }, status: :forbidden unless ph[:admin].present?
    end
  end
end
