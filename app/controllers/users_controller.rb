class UsersController < ApplicationController

  # GET /users
  def index
    @users = User.all.order(:user_name)

    render json: @users
  end
end
