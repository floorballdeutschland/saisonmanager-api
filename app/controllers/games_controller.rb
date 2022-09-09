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

  def next_period_info
    game = Game.find(params[:id])
    league = game.league

    current_period = 0
    # prüfe ob events vorliegen, bestimme aktuelle periode
    current_period = game.events.map { |e| e['period'] }.max game.events.present?

    next_period = current_period + 1
    next_period_title = league.period_title next_period
    next_period_length = league.period_time next_period
    is_extratime = league.period_is_extratime next_period

    render json: {
      current_period:,
      next_period:,
      next_period_title:,
      next_period_length:,
      is_extratime:
    }
  end
end
