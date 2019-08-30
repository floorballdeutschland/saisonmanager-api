class GamesController < ApplicationController
  skip_before_action :authenticate_user

  # GET /games
  def index
    @games = Game.all
  end

  # GET /games/1
  def show
    @game = Game.find(params[:id])
  end

  def users_games
    game_days = GameDay.past_games

    @games = game_days.map(&:games).flatten
  end
end
