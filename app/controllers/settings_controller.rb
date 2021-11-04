class SettingsController < ApplicationController
  skip_before_action :authenticate_user

  # GET /settings
  def index
    @settings = Setting.all

    render json: @settings
  end

  def init
    @result ||= {
      seasons: Setting.seasons,
      current_season_id: Setting.current_season,
      game_operations: GameOperation.all.map(&:short_hash)
    }

    render json: @result
  end
end
