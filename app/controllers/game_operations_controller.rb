class GameOperationsController < ApplicationController
  
  # GET /game_operations
  def index
    @game_operations = GameOperation.all

    render json: @game_operations
  end
end
