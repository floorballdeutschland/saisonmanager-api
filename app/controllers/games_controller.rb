class GamesController < ApplicationController
  #skip_before_action :authenticate_user

  # GET /games
  def index
    @games = Game.all
  end

  # GET /games/1
  def show
    @game = Game.find(params[:id])
  end
end
