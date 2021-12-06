class ApplicationController < ActionController::Base
  include ActionController::MimeResponds
  before_action :authenticate_user

  private
  def authenticate_user
    user_id = cookies.signed[:user_id]
    @user = User.find_by_id user_id if user_id
    render json: { success: false, message: 'Not authenticated' }, status: 401 unless user_id
  end
end
