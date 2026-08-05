# frozen_string_literal: true

# Öffentlicher Antrag auf einen API-Zugang, ohne Benutzerkonto. Bedient das
# Formular unter /api-zugang sowie das Abholen des genehmigten Keys über einen
# Einmal-Link.
#
# Der Endpunkt verlangt einen API-Key (authenticate_public_request), den das
# eigene Frontend über den ApiKeyInterceptor mitschickt. Das ist keine
# Berechtigungsprüfung, sondern eine Hürde gegen Skript-Einsendungen; gegen
# Massen-Einsendungen und das Durchprobieren von Tokens greift zusätzlich ein
# IP-Throttle (config/initializers/rack_attack.rb).
class ApiKeyApplicationsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[create terms_version show_reveal reveal]
  before_action :authenticate_public_request, only: %i[create terms_version show_reveal reveal]

  INVALID_MESSAGE = 'Dieser Link ist ungültig.'

  # GET /api/v2/api_terms_version
  # Das Formular schickt die Fassung mit, der es zugestimmt hat. Damit Frontend
  # und Server nicht auseinanderlaufen, holt es sie hier ab statt sie selbst zu
  # kennen.
  def terms_version
    render json: { version: ApiTerms::VERSION }
  end

  # POST /api/v2/api_key_applications
  def create
    error = submission_error
    return render json: { errors: [error] }, status: :unprocessable_entity if error

    application = ApiKeyApplication.new(application_params)
    application.accepted_terms_at = Time.current
    application.accepted_terms_ip = request.ip

    unless application.save
      return render json: { errors: application.errors.full_messages }, status: :unprocessable_entity
    end

    ApiKeyApplicationMailer.submitted_notification(application).deliver_later
    render json: { success: true }, status: :created
  end

  # GET /api/v2/api_key_applications/reveal/:token
  # Liefert nur den Zustand des Links und verbraucht ihn bewusst NICHT:
  # Mail-Programme und Virenscanner rufen Links vorab ab und würden die
  # einmalige Anzeige sonst ins Leere laufen lassen.
  def show_reveal
    application = ApiKeyApplication.find_by_reveal_token(params[:token])
    return render json: { state: 'invalid', message: INVALID_MESSAGE }, status: :gone if application.nil?

    render json: {
      state: application.reveal_state,
      organisation: application.organisation,
      expires_at: application.reveal_token_expires_at&.iso8601
    }
  end

  # POST /api/v2/api_key_applications/reveal
  def reveal
    application = ApiKeyApplication.find_by_reveal_token(params[:token])
    return gone if application.nil?

    raw_key = application.reveal_key!
    return gone if raw_key.blank?

    render json: { raw_key: raw_key, name: application.api_key&.name }
  end

  private

  def gone
    render json: { message: INVALID_MESSAGE }, status: :gone
  end

  # Gründe, die den Antrag vor dem Speichern abweisen. Der kommerzielle Fall wird
  # zusätzlich im Modell geprüft, damit ein Direktaufruf die Weiche im Formular
  # nicht umgeht.
  def submission_error
    unless truthy?(params.dig(:api_key_application, :accept_terms))
      return 'Bitte bestätige die Nutzungsvereinbarung.'
    end
    return ApiKeyApplication::COMMERCIAL_HINT if truthy?(params.dig(:api_key_application, :commercial))

    return nil if params.dig(:api_key_application, :terms_version) == ApiTerms::VERSION

    'Die Nutzungsbedingungen wurden aktualisiert. Bitte lade die Seite neu und prüfe die neue Fassung.'
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value).present?
  end

  def application_params
    params.require(:api_key_application)
          .permit(:commercial, :organisation, :contact_name, :email, :address,
                  :project_description, :purpose, :project_url, :terms_version)
  end
end
