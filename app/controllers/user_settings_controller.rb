# Self-Service-Einstellungen des eingeloggten Users (Sprache, Passwort).
# Nicht zu verwechseln mit Admin::UsersController (Verwaltung fremder User).
class UserSettingsController < ApplicationController
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

    current_user.update!(receive_info_mails: ActiveModel::Type::Boolean.new.cast(params[:receive_info_mails]))
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

  private

  def password_params
    params.permit(:password, :password_confirmation)
  end
end
