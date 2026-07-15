class ApplicationController < ActionController::Base
  include ActionController::MimeResponds
  protect_from_forgery with: :exception
  before_action :authenticate_user
  before_action :save_current_user # https://gist.github.com/kule/9425fb7d4c2a13e556ef
  before_action :set_paper_trail_whodunnit
  after_action :set_csrf_cookie

  # rescue_from-Handler werden von Rails in umgekehrter Definitionsreihenfolge
  # geprüft: Der zuletzt passende (= zuerst definierte) fängt zuletzt. Deshalb
  # steht der generische StandardError-Fallback OBEN und die spezifischen
  # Handler darunter, damit sie zuerst greifen.
  rescue_from StandardError do |e|
    # In dev/test durchreichen, damit Stacktraces sichtbar bleiben und
    # Test-Suiten nicht maskiert werden.
    raise if Rails.env.development? || Rails.env.test?

    Rails.logger.error("#{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n")) if e.backtrace
    Sentry.capture_exception(e) if defined?(Sentry)
    render json: { success: false, message: 'Server-Fehler.' }, status: :internal_server_error
  end

  rescue_from ActionController::InvalidAuthenticityToken do
    render json: { success: false, message: 'CSRF token ungültig.' }, status: :forbidden
  end

  rescue_from ActiveRecord::RecordNotFound do
    render json: { success: false, message: 'Nicht gefunden.' }, status: :not_found
  end

  rescue_from ActionController::ParameterMissing, ActionController::UnpermittedParameters do |e|
    render json: { success: false, message: e.message }, status: :unprocessable_entity
  end

  rescue_from ActiveRecord::RecordInvalid do |e|
    render json: { success: false, message: e.message, errors: e.record.errors }, status: :unprocessable_entity
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

  # Serverseitige Prüfung für Vereins-/Team-Logo-Uploads (analog zu den Banner-Endpunkten).
  # Gibt eine erklärende Fehlermeldung zurück oder nil, wenn die Datei zulässig ist.
  LOGO_ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/svg+xml image/webp].freeze
  LOGO_MAX_SIZE = 3.megabytes

  def logo_upload_error(file)
    unless LOGO_ALLOWED_CONTENT_TYPES.include?(file.content_type)
      return 'Ungültiges Dateiformat. Erlaubt sind PNG, JPG, SVG oder WebP.'
    end

    return "Die Datei ist zu groß. Maximal #{LOGO_MAX_SIZE / 1.megabyte} MB erlaubt." if file.size > LOGO_MAX_SIZE

    # SVG ist vektorbasiert und skaliert verlustfrei, daher entfällt die Quadrat-Prüfung.
    return nil if file.content_type == 'image/svg+xml'

    require 'vips'
    begin
      image = Vips::Image.new_from_file(file.tempfile.path)
    rescue Vips::Error
      return 'Die Datei konnte nicht als Bild gelesen werden.'
    end

    return 'Das Logo muss quadratisch sein (gleiche Breite und Höhe).' unless image.width == image.height

    nil
  end
end
