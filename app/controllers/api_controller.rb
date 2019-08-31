class ApiController < ApplicationController
  skip_before_action :authenticate_user

  # GET api/v1/ticker/fvd/10/leagues
  def leagues
    goid = params[:game_operation_id] == 'fvd' ? 1 : 1
    #result = League.where(season_id: params[:season_id], game_operation_id: goid).includes(:game_days).map(&:ticker_hash)
    result = League.where(id: Setting.liveticker_leagues(season_id, goid)).includes(:game_days).map(&:ticker_hash)

    render json: result
  end

    # GET api/v1/ticker/games/0815
    def games
      game = Game.find(params[:id])

      render json: game.ticker_hash
    end
end
