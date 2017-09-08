class LeaguesController < ApplicationController
  skip_before_action :authenticate_user

  # GET /leagues
  def index
    @leagues = League.all.order(season_id: :desc, game_operation_id: :asc).order("order_key::int")
    @gos = {}
    GameOperation.all.each { |go| @gos[go.id] = go }
  end

  # GET /leagues/1
  def show
    @league = League.find(params[:id])
  end
end
