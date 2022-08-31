class SessionsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[login logout]

  # POST /login
  def login
    username = params[:username]
    password = params[:password]

    user = User.login(username, password)

    if user
      cookies.signed[:user_id] = { value: user.id, httponly: true, expires: 7.days }

      render json: { success: true, user: user.login_hash }
    else
      render json: { success: false }, status: :unauthorized
    end
  end

  def logout
    cookies.delete :user_id
    render json: { success: true }, status: :ok
  end
end
