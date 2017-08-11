class TeamsController < ApplicationController

  # GET /teams
  def index
    @teams = Team.all

    render json: @teams
  end
end
