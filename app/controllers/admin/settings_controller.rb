module Admin
  class SettingsController < ApplicationController
    before_action :require_admin!

    def seasons
      render json: {
        current_season_id: Setting.current_season_id,
        seasons: Setting.seasons
      }
    end

    def create_season
      name = params[:name].to_s.strip
      return render json: { error: 'Name darf nicht leer sein' }, status: :unprocessable_entity if name.blank?

      setting = Setting.first
      next_id = (setting.seasons.keys.map(&:to_i).max || 0) + 1

      setting.seasons = setting.seasons.merge(next_id.to_s => { 'name' => name })
      setting.save!

      render json: { id: next_id, name: name, current: false }, status: :created
    end

    def update_season
      new_id = params[:season_id].to_i
      setting = Setting.first
      unless setting.seasons.key?(new_id.to_s)
        return render json: { error: 'Unbekannte Saison-ID' }, status: :unprocessable_entity
      end

      systems = (setting.systems || {}).dup
      systems['1'] = (systems['1'] || {}).merge('current_season_id' => new_id)
      setting.systems = systems
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
