class TransfersController < ApplicationController

  # GET /transfers
  def index
    @transfers = Transfer.all

    render json: @transfers
  end
end
