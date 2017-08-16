class LeaguesController < ApplicationController
  skip_before_action :authenticate_user

  # GET /leagues
  def index
    @leagues = League.all

    render json: @leagues
  end

  # GET /leagues/1
  def show
    @league = League.find(params[:id])
  end
end
