class ApplicationController < ActionController::Base
  include ActionController::MimeResponds
  protect_from_forgery with: :exception
  before_action :authenticate_user
  before_action :save_current_user # https://gist.github.com/kule/9425fb7d4c2a13e556ef
  before_action :set_paper_trail_whodunnit
  after_action :set_csrf_cookie

  rescue_from ActionController::InvalidAuthenticityToken do
    render json: { success: false, message: 'CSRF token ungültig.' }, status: :forbidden
  end

  private

  # CSRF nur für authentifizierte Requests erzwingen
  def verified_request?
    super || !current_user
  end

  def set_csrf_cookie
    cookies['XSRF-TOKEN'] = {
      value: form_authenticity_token,
      secure: Rails.env.production?,
      same_site: :strict
    }
  end

  def authenticate_user
    @user = current_user
    render json: { success: false, message: 'Not authenticated' }, status: 401 unless @user
  end

  def authenticate_public_request
    return if current_user

    raw_key = request.headers['X-Api-Key']
    @api_key = ApiKey.authenticate(raw_key)
    return if @api_key

    render json: { success: false, message: 'API key required' }, status: :unauthorized
  end

  def api_key_request?
    @api_key.present?
  end

  def current_user
    user_id = cookies.signed[:user_id]
    User.find_by_id user_id if user_id
  end

  def save_current_user
    User.current_user = current_user
  end
end
