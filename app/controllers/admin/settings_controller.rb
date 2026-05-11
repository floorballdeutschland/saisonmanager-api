module Admin
  class SettingsController < ApplicationController
    before_action :require_admin!

    def seasons
      render json: {
        current_season_id: Setting.current_season_id,
        seasons: Setting.seasons
      }
    end

    def update_season
      new_id = params[:season_id].to_i
      setting = Setting.first
      unless setting.seasons.key?(new_id.to_s)
        return render json: { error: 'Unbekannte Saison-ID' }, status: :unprocessable_entity
      end

      setting.systems ||= {}
      setting.systems['1'] ||= {}
      setting.systems['1']['current_season_id'] = new_id
      setting.save!

      render json: { current_season_id: new_id }
    end

    private

    def require_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
