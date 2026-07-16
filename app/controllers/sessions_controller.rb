class SessionsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[login logout lost_password]
  skip_before_action :verify_authenticity_token, only: %i[login logout lost_password]

  # POST /login
  def login
    username = params[:username].downcase
    password = params[:password]

    user = User.login(username, password)

    if user&.archived?
      render json: { success: false, message: 'Dieses Benutzerkonto wurde archiviert.' }, status: :unauthorized
    elsif user
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

  def lost_password
    cookies.delete :user_id

    User.find_by(user_name: params[:username].downcase)&.send_reset_information

    render json: { success: true }, status: :ok
  end
end
