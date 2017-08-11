class ClubsController < ApplicationController
  
  # GET /clubs
  def index
    @clubs = Clubs.all

    render json: @clubs
  end
end
