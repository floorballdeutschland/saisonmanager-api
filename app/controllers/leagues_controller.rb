class LeaguesController < ApplicationController

  # GET /leagues
  def index
    @leagues = League.all

    render json: @leagues
  end
end
