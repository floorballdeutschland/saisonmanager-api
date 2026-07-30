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
    return unless user_id

    user = User.find_by_id(user_id)
    # Archivierte Konten gelten als nicht angemeldet – auch eine noch gültige
    # Cookie-Session (bis 7 Tage) endet damit sofort per 401 (Frontend loggt aus).
    user unless user&.archived?
  end

  def save_current_user
    User.current_user = current_user
  end

  # Serverseitige Prüfung für Bild-Uploads (Vereins-, Team- und Verbandslogos sowie Banner).
  # Gibt eine erklärende Fehlermeldung zurück oder nil, wenn die Datei zulässig ist.
  # Nur Raster-Formate: SVG ist bewusst ausgeschlossen, weil ActiveStorage SVG als
  # Binary/Attachment ausliefert (Logos würden nicht als <img> rendern) und ein
  # nicht bereinigtes SVG bei Inline-Auslieferung ein Stored-XSS-Vektor wäre.
  LOGO_ALLOWED_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  LOGO_MAX_SIZE = 3.megabytes

  # square: Vereins- und Teamlogos werden in quadratischen Kacheln und Tabellenzeilen
  # ausgespielt und müssen deshalb quadratisch geliefert werden. Verbandslogos und
  # Banner laufen dagegen über die Breite und sind fast immer Wortmarken im
  # Querformat; ein Quadrat-Zwang würde dort jede reale Vorlage abweisen.
  def logo_upload_error(file, square: true, max_size: LOGO_MAX_SIZE)
    # Kein hochgeladenes File (z. B. String-Parameter): sauber als 422 abweisen,
    # statt bei file.content_type mit NoMethodError (500) abzubrechen.
    return 'Ungültige Bilddatei.' unless file.respond_to?(:content_type) && file.respond_to?(:tempfile)

    unless LOGO_ALLOWED_CONTENT_TYPES.include?(file.content_type)
      return 'Ungültiges Dateiformat. Erlaubt sind PNG, JPG oder WebP.'
    end

    if file.size > max_size
      # number_to_human_size statt Division durch 1.megabyte: Das Bannerlimit liegt
      # unter einem Megabyte und wäre sonst als "Maximal 0 MB erlaubt" gemeldet worden.
      return "Die Datei ist zu groß. Maximal #{ActiveSupport::NumberHelper.number_to_human_size(max_size)} erlaubt."
    end

    require 'vips'
    begin
      image = Vips::Image.new_from_file(file.tempfile.path)
    rescue Vips::Error
      return 'Die Datei konnte nicht als Bild gelesen werden.'
    end

    return 'Das Logo muss quadratisch sein (gleiche Breite und Höhe).' if square && image.width != image.height

    nil
  end
end
