class SettingsController < ApplicationController

  # GET /settings
  def index
    @settings = Setting.all

    render json: @settings
  end
end
