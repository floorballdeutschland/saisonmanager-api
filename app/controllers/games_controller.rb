class GamesController < ApplicationController

  # GET /games
  def index
    @games = Arena.all

    render json: @games
  end
end
