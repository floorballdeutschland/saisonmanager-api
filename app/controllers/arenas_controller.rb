class ArenasController < ApplicationController

  # GET /arenas
  def index
    @arenas = Arena.all

    render json: @arenas
  end
end
