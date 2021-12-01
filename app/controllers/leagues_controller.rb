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
    league = League.find(params[:id])

    render json: league.full_hash(true)
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


  # GET /leagues/1/game_days/15/schedule
  def game_day_schedule
    @league = League.find(params[:id])

    render json: @league.game_day_schedule(params[:game_day_number])
  end

  # GET /leagues/1/game_days/current/schedule
  def current_schedule
    @league = League.find(params[:id])

    render json: @league.current_schedule
  end

  # GET /leagues/1/scorer
  api :GET, '/leagues/:id/scorer.json'
  param :id, :number,
        required: true, desc: 'league id'
  #short_description 'Prints the scorer table for league :id.'
  description <<-EOS
      Prints the scorer table for league :id.
    EOS
  def scorer
    @league = League.find(params[:id])

    render json:@league.scorer
  end

  # GET /leagues/1/table
  api :GET, '/leagues/:id/table.json'
  param :id, :number,
        required: true, desc: 'league id'
  #short_description 'Prints the table for league :id.'
  description <<-EOS
      Prints the table for league :id.
    EOS
  def table
    @league = League.find(params[:id])

    render json: @league.table
  end

  def license_list
    @league = League.find(params[:id])

  end

  def meta
    @league = League.find(params[:id])

    render json:@league.meta_item
  end
end
