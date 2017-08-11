class SessionsController < ApplicationController

  # POST /login
  def login
    logger.warn params.to_json
    username = params[:username]
    password = params[:password]

    user = User.login(username, password)
    token = User.generate_token(user) if user

    if user
      render json: {user: user, token: token}
    else
      render json: {success: false}, status: 401
    end
  end
end
