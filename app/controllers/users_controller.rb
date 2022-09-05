class UsersController < ApplicationController
  skip_before_action :authenticate_user, only: %i[reset_password_token]
  # GET /users
  def index
    @users = User.all.order(:user_name)

    render json: @users
  end

  def reset_password_token
    user = User.find_by(password_reset_token: params[:reset_token])

    if user.update(reset_password_params) && user.update(password_reset_token: nil)
      render json: { success: true }
    else
      render json: user.errors, status: :unprocessable_entity
    end
  end

  def reset_password_params
    params.require(:user).permit(:password, :password_confirmation)
  end
end
