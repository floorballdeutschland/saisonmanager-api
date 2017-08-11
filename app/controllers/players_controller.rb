class PlayersController < ApplicationController

  # GET /players
  def index
    @players = Player.all

    render json: @players
  end
end
