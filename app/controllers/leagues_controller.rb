class LeaguesController < ApplicationController
  skip_before_action :authenticate_user, except: [:show]

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

  # GET /leagues/1/schedule
  api :GET, '/leagues/:id/schedule.json'
  param :id, :number,
        required: true, desc: 'league id'
  #short_description 'Prints the game schedule for league :id.'
  description <<-EOS
      Prints the game schedule for league :id. If the game was already played a result_string is included.
    EOS
  def schedule
    @league = League.find(params[:id])

    render json:@league.schedule
  end

  def meta
    @league = League.find(params[:id])

    render json:@league.meta_item
  end
end