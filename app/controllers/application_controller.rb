class ApplicationController < ActionController::API
  include ActionController::MimeResponds
  before_action :authenticate_user

  private
  def authenticate_user
    token = (request.headers['Authorization'] || '').split(' ').last
    user_id = User.check_token token
    @user = User.find_by_id user_id if user_id
    render json: { success: false, message: 'Not authenticated' }, status: 401 unless user_id
  end
end
