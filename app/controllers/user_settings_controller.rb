# Self-Service-Einstellungen des eingeloggten Users (Name, Sprache, Passwort).
# Nicht zu verwechseln mit Admin::UsersController (Verwaltung fremder User).
class UserSettingsController < ApplicationController
  # Der Bestätigungslink aus der Mail wird ohne Login geöffnet – das Token ist
  # dort das eigentliche Geheimnis (Muster wie users#reset_password_token).
  skip_before_action :authenticate_user, only: %i[confirm_email]
  before_action :authenticate_public_request, only: %i[confirm_email]

  MAX_NAME_LENGTH = 50
  NAME_LOCKED_MESSAGE = 'Dein Name steht auf deinem Schiedsrichterausweis und kann deshalb nicht selbst geändert ' \
                        'werden. Wende dich dafür an deine Verbandsgeschäftsstelle.'.freeze

  # PATCH /api/v2/user/name
  # Grundsätzlich darf jede Person ihren eigenen Vor- und Nachnamen pflegen
  # (z. B. Schreibfehler, Namensänderung nach Heirat); die Ausnahme für
  # Schiedsrichter steht unten. Der Benutzername bleibt bewusst
  # ausgeschlossen: er ist die Login-Kennung und wird nur über die
  # Benutzerverwaltung geändert.
  def update_name
    # Konten mit verknüpfter Schiedsrichter-Lizenz sind ausgenommen: Der Name
    # steht auf dem digitalen Schiedsrichterausweis (/schiedsrichter/ausweis),
    # der bei Partnern Vergünstigungen gewährt. Selbstpflege wäre dort eine
    # Fälschungsmöglichkeit, deshalb bleibt der Name der Geschäftsstelle
    # vorbehalten (Schiedsrichterverwaltung). Gegenstück im Schiri-Profil:
    # RefereeProfileController#profile_params.
    #
    # 422 statt 403: Der ErrorInterceptor im Frontend navigiert bei 403 auf die
    # Startseite. Hier soll die Person auf „Mein Konto" bleiben und die
    # Begründung lesen.
    if current_user.referee_id.present?
      return render json: { success: false, message: NAME_LOCKED_MESSAGE },
                    status: :unprocessable_entity
    end

    first_name = params[:first_name].to_s.strip
    last_name = params[:last_name].to_s.strip

    if first_name.blank? || last_name.blank?
      return render json: { success: false, message: 'Vor- und Nachname dürfen nicht leer sein.' },
                    status: :unprocessable_entity
    end

    if first_name.length > MAX_NAME_LENGTH || last_name.length > MAX_NAME_LENGTH
      return render json: { success: false,
                            message: "Vor- und Nachname dürfen höchstens #{MAX_NAME_LENGTH} Zeichen lang sein." },
                    status: :unprocessable_entity
    end

    # current_user ist NICHT memoisiert und liefert bei jedem Aufruf eine frisch
    # geladene Instanz (ApplicationController#current_user). Die Referenz daher
    # einmal festhalten, sonst läge errors nach einem Fehlschlag auf einem
    # anderen Objekt und die Antwort trüge eine leere message.
    user = current_user

    if user.update(first_name:, last_name:)
      render json: { success: true, user: user.login_hash }
    else
      message = user.errors.full_messages.presence&.join(', ')
      render json: { success: false, message: message || 'Name konnte nicht gespeichert werden.' },
             status: :unprocessable_entity
    end
  end

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
    # und würde fälschlich success: true melden. Daher hier explizit prüfen (die
    # Regeln decken den leeren Fall mit ab).
    policy_error = PasswordPolicy.error_for(params[:password])
    if policy_error
      return render json: { success: false, message: policy_error }, status: :unprocessable_entity
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

    # Mail-Bombing bremsen: pro Konto höchstens eine Bestätigungsmail pro
    # Minute (die Adresse ist frei wählbar, der Versand geht an Fremde). Die
    # verbleibende Wartezeit gehört in die Meldung: „Bitte warte einen Moment"
    # ließ offen, ob es um Sekunden oder um die 24 Stunden Linkgültigkeit geht.
    retry_after = email_change_retry_after_seconds
    if retry_after.positive?
      response.headers['Retry-After'] = retry_after.to_s
      return render json: { success: false, retry_after: retry_after,
                            message: "Bitte warte noch #{retry_after} Sekunden, bevor du erneut eine " \
                                     'Bestätigungsmail anforderst.' },
                    status: :too_many_requests
    end

    # Mehrfachvergabe ist ausdrücklich erlaubt (Sammelpostfach eines Vereins,
    # Schiri- und Vereinsmanager-Konto derselben Person). Der Login läuft nur
    # über den Benutzernamen, die Adresse ist also keine Kennung und muss nicht
    # eindeutig sein. Wir weisen aber darauf hin, damit ein Tippfehler auf einer
    # fremden Adresse nicht unbemerkt bleibt.
    raw_token = current_user.start_email_change!(new_email)
    UserMailer.confirm_email_change(current_user, raw_token).deliver_later
    render json: { success: true, user: current_user.login_hash, email_in_use: email_in_use?(new_email) }
  end

  # POST /api/v2/user/email/confirm – öffentlich, Token aus dem Mail-Link.
  def confirm_email
    user = User.find_by_email_confirmation_token(params[:token])
    unless user
      return render json: { success: false, message: 'Ungültiger oder abgelaufener Link.' },
                    status: :not_found
    end

    # Kein Eindeutigkeitscheck beim Übernehmen: Eine mehrfach vergebene Adresse
    # ist zulässig (siehe update_email). Wer den Link in der Mail geklickt hat,
    # hat die Adresse nachweislich in der Hand.
    user.confirm_email_change!
    render json: { success: true, email: user.email }
  end

  private

  # Verbleibende Wartezeit bis zur nächsten Bestätigungsmail in ganzen Sekunden
  # (aufgerundet), 0 wenn sofort angefordert werden darf.
  def email_change_retry_after_seconds
    started_at = current_user.email_change_started_at
    return 0 if started_at.blank?

    remaining = (started_at + User::EMAIL_CONFIRMATION_RESEND_INTERVAL) - Time.current
    remaining.positive? ? remaining.ceil : 0
  end

  # Nur für den Hinweistext: Nutzt bereits ein anderes Konto diese Adresse oder
  # hat eine offene (noch nicht abgelaufene) Änderung darauf laufen?
  def email_in_use?(new_email)
    User.where('LOWER(email) = ?', new_email).where.not(id: current_user.id).exists? ||
      User.where('LOWER(pending_email) = ?', new_email).where.not(id: current_user.id)
          .where('email_confirmation_expires_at > ?', Time.current).exists?
  end

  def password_params
    params.permit(:password, :password_confirmation)
  end
end
