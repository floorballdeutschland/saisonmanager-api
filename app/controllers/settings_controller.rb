class SettingsController < ApplicationController
  skip_before_action :authenticate_user
  before_action :authenticate_public_request

  # GET /settings
  def index
    @settings = Setting.all

    render json: @settings
  end

  def init
    result = Rails.cache.fetch('settings/init', expires_in: 30.minutes) do
      {
        seasons: Setting.seasons,
        current_season_id: Setting.current_season_id,
        game_operations: GameOperation.all.map(&:short_hash),
        state_associations: StateAssociation.with_attached_logo.order(:name).map(&:short_hash)
      }
    end

    render json: result
  end
end
