class GamesController < ApplicationController
  skip_before_action :authenticate_user

  # GET /games
  def index
    @games = Game.all
  end

  # GET /games/1
  def show
    game = Game.find(params[:id])

    hash = game.full_hash
    hash[:permission] = game.user_permissions(current_user) if current_user

    render json: hash
  end

  def users_games
    game_days = GameDay.past_games

    @games = game_days.map(&:games).flatten
  end

  def update_start_end
    Game.start_end_games
  end
end
