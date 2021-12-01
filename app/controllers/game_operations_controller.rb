class GameOperationsController < ApplicationController
  before_action :set_game_operation, only: [:index_leagues]
  skip_before_action :authenticate_user

  # GET /game_operations
  def index
    @game_operations = GameOperation.all.order(:id)

    render json: @game_operations
  end

  # GET /game_operations/1/leagues
  def index_leagues
    current_season = Setting.current_season

    leagues = @game_operation.leagues.order('order_key::int')
    leagues = if params[:season_id]
                 leagues.where(season_id: params[:season_id])
               else
                 leagues.where(season_id: current_season)
               end

    render json: leagues.map(&:full_hash)
  end

  # GET /game_operations/by_shortname/:name
  def by_shortname
    @game_operation = GameOperation.find_by path: params[:name]
    render json: @game_operation
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_game_operation
      @game_operation = GameOperation.find(params[:id])
    end
end
