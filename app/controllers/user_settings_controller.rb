# Self-Service-Einstellungen des eingeloggten Users (Sprache, Passwort).
# Nicht zu verwechseln mit Admin::UsersController (Verwaltung fremder User).
class UserSettingsController < ApplicationController
  # Der Bestätigungslink aus der Mail wird ohne Login geöffnet – das Token ist
  # dort das eigentliche Geheimnis (Muster wie users#reset_password_token).
  skip_before_action :authenticate_user, only: %i[confirm_email]
  before_action :authenticate_public_request, only: %i[confirm_email]

  MIN_PASSWORD_LENGTH = 8

  # PATCH /api/v2/user/language
  def update_language
    language = params[:language].to_s

    unless User::LANGUAGES.include?(language)
      return render json: { success: false, message: 'Ungültige Sprache.' },
                    status: :unprocessable_entity
    end

    current_user.update!(language:)
    render json: { success: true, user: current_user.login_hash }
  end

  # PATCH /api/v2/user/mail-preferences
  # Schaltet den Empfang informeller System-Mails an/aus. Nur für Teammanager;
  # andere Rollen (VM o. a.) dürfen die Einstellung nicht ändern.
  def update_mail_preferences
    unless current_user.permission_hash[:tm].present?
      return render json: { success: false, message: 'Nicht berechtigt.' }, status: :forbidden
    end

    # Fehlender/uneindeutiger Wert würde via cast → nil zu einer NOT-NULL-Verletzung
    # (500) führen; daher explizit prüfen (analog zu update_language/update_password).
    value = ActiveModel::Type::Boolean.new.cast(params[:receive_info_mails])
    if value.nil?
      return render json: { success: false, message: 'Ungültiger Wert.' }, status: :unprocessable_entity
    end

    current_user.update!(receive_info_mails: value)
    render json: { success: true, user: current_user.login_hash }
  end

  # PUT /api/v2/user/password
  def update_password
    unless current_user.authenticate(params[:current_password].to_s)
      return render json: { success: false, message: 'Aktuelles Passwort ist falsch.' },
                    status: :unprocessable_entity
    end

    # has_secure_password erzwingt die Passwort-Presence nur beim Create, nicht beim Update:
    # ein leeres :password ließe current_user.update wortlos durchlaufen (digest unverändert)
    # und würde fälschlich success: true melden. Daher hier explizit prüfen.
    if params[:password].to_s.length < MIN_PASSWORD_LENGTH
      return render json: { success: false,
                            message: "Das neue Passwort muss mindestens #{MIN_PASSWORD_LENGTH} Zeichen lang sein." },
                    status: :unprocessable_entity
    end

    if current_user.update(password_params)
      render json: { success: true }
    else
      render json: { success: false, message: current_user.errors.full_messages.join(', ') },
             status: :unprocessable_entity
    end
  end

  # PATCH /api/v2/user/email
  # Startet die Änderung der eigenen E-Mail-Adresse: Die neue Adresse wird als
  # pending_email vorgemerkt, ein Bestätigungslink geht an die NEUE Adresse und
  # ist 24h gültig. Erst die Bestätigung übernimmt die Adresse (Double-Opt-In).
  def update_email
    unless current_user.authenticate(params[:current_password].to_s)
      return render json: { success: false, message: 'Aktuelles Passwort ist falsch.' },
                    status: :unprocessable_entity
    end

    new_email = params[:email].to_s.strip.downcase
    unless new_email.match?(URI::MailTo::EMAIL_REGEXP)
      return render json: { success: false, message: 'Ungültige E-Mail-Adresse.' },
                    status: :unprocessable_entity
    end

    if new_email == current_user.email.to_s.downcase
      return render json: { success: false, message: 'Das ist bereits deine aktuelle E-Mail-Adresse.' },
                    status: :unprocessable_entity
    end

    # email hat keinen Unique-Constraint; der Login per E-Mail funktioniert aber
    # nur bei eindeutiger Adresse (User.login). Kollisionen daher hier abfangen.
    if email_taken?(new_email)
      return render json: { success: false, message: 'Diese E-Mail-Adresse wird bereits verwendet.' },
                    status: :unprocessable_entity
    end

    # Mail-Bombing bremsen: pro Konto höchstens eine Bestätigungsmail pro
    # Minute (die Adresse ist frei wählbar, der Versand geht an Fremde).
    started_at = current_user.email_change_started_at
    if started_at && started_at > User::EMAIL_CONFIRMATION_RESEND_INTERVAL.ago
      return render json: { success: false,
                            message: 'Bitte warte einen Moment, bevor du erneut eine Bestätigungsmail anforderst.' },
                    status: :too_many_requests
    end

    raw_token = current_user.start_email_change!(new_email)
    UserMailer.confirm_email_change(current_user, raw_token).deliver_later
    render json: { success: true, user: current_user.login_hash }
  end

  # POST /api/v2/user/email/confirm – öffentlich, Token aus dem Mail-Link.
  def confirm_email
    user = User.find_by_email_confirmation_token(params[:token])
    unless user
      return render json: { success: false, message: 'Ungültiger oder abgelaufener Link.' },
                    status: :not_found
    end

    # Zwischen Anstoßen und Bestätigen kann die Adresse anderweitig vergeben
    # worden sein – deshalb beim Übernehmen erneut prüfen.
    if User.where.not(id: user.id).where('LOWER(email) = ?', user.pending_email.to_s.downcase).exists?
      return render json: { success: false, message: 'Diese E-Mail-Adresse wird inzwischen bereits verwendet.' },
                    status: :unprocessable_entity
    end

    user.confirm_email_change!
    render json: { success: true, email: user.email }
  end

  private

  def email_taken?(new_email)
    User.where('LOWER(email) = ?', new_email).where.not(id: current_user.id).exists? ||
      User.where('LOWER(pending_email) = ?', new_email).where.not(id: current_user.id)
          .where('email_confirmation_expires_at > ?', Time.current).exists?
  end

  def password_params
    params.permit(:password, :password_confirmation)
  end
end
