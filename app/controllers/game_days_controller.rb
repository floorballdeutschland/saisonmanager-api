class GameDaysController < ApplicationController
  
  # GET /game_days
  def index
    @game_days = GameDay.all

    render json: @game_days
  end
end
