class ApplicationController < ActionController::API
  before_action :authenticate_user

  private
  def authenticate_user
    token = (request.headers['Authorization'] || '').split(' ').last
    render json: { success: false, message: 'Not authenticated' }, status: 401 unless User.check_token token
  end
end
