class ApplicationController < ActionController::Base
  include ActionController::MimeResponds
  before_action :authenticate_user
  before_action :save_current_user # https://gist.github.com/kule/9425fb7d4c2a13e556ef

  private

  def authenticate_user
    @user = current_user
    render json: { success: false, message: 'Not authenticated' }, status: 401 unless @user
  end

  def current_user
    user_id = cookies.signed[:user_id]
    User.find_by_id user_id if user_id
  end

  def save_current_user
    User.current_user = current_user
  end
end
