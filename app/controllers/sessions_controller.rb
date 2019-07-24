class SessionsController < ApplicationController
  skip_before_action :authenticate_user

  # POST /login
  def login
    logger.warn params.to_json
    username = params[:username]
    password = params[:password]

    user = User.login(username, password)
    expiration = (Time.now + 1.days).to_i
    token = User.generate_token(user, expiration) if user

    if user
      render json: {user: user, token: token, expiresAt: expiration}
    else
      render json: {success: false}, status: 401
    end
  end
end
