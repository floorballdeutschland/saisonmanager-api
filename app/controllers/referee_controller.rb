class RefereeController < ApplicationController
  skip_before_action :authenticate_user

  # GET /referee/id/games.json
  def games
    games = Game.by_referee_id(params[:id])

    render json: games.map(&full_hash)
  end
end
