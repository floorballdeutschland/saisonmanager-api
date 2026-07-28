class SessionsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[login logout lost_password forgot_username]
  skip_before_action :verify_authenticity_token, only: %i[login logout lost_password forgot_username]

  # Hinweis für Nutzer, die ihre E-Mail-Adresse ins Login-Feld tippen. Die
  # Entscheidung fällt rein syntaktisch am @ und ohne Datenbankzugriff, damit
  # sich daraus nicht ablesen lässt, welche Adressen im System existieren.
  EMAIL_LOGIN_HINT = 'Bitte melde dich mit deinem Benutzernamen an, nicht mit deiner E-Mail-Adresse.'.freeze

  # Wartezeit zwischen zwei Benutzernamen-Erinnerungen an dieselbe Adresse. Der
  # Endpunkt ist offen und verschickt Mail an eine frei wählbare Adresse; ohne
  # Bremse ließe sich damit ein fremdes Postfach zumüllen.
  FORGOT_USERNAME_INTERVAL = 5.minutes

  # POST /login
  def login
    username = params[:username].to_s.downcase
    password = params[:password]

    user = User.login(username, password)

    if user&.archived?
      render json: { success: false, message: 'Dieses Benutzerkonto wurde archiviert.' }, status: :unauthorized
    elsif user
      cookies.signed[:user_id] = { value: user.id, httponly: true, expires: 7.days }

      render json: { success: true, user: user.login_hash }
    elsif username.include?('@')
      render json: { success: false, message: EMAIL_LOGIN_HINT }, status: :unauthorized
    else
      render json: { success: false }, status: :unauthorized
    end
  end

  def logout
    cookies.delete :user_id
    render json: { success: true }, status: :ok
  end

  def lost_password
    cookies.delete :user_id

    # Ohne diesen Hinweis läuft eine eingetippte E-Mail-Adresse ins Leere: Die
    # Suche geht ausschließlich über den Benutzernamen, die Antwort ist aber
    # (bewusst) immer success, sodass niemand merkt, dass keine Mail rausgeht.
    if params[:username].to_s.include?('@')
      return render json: { success: false, message: EMAIL_LOGIN_HINT }, status: :unprocessable_entity
    end

    # Archivierte Konten erhalten keine Reset-Mail, ein Login ist ohnehin gesperrt.
    # Benutzername kleinschreibungsneutral suchen (wie beim Login), damit auch
    # Bestandsnamen mit Großbuchstaben eine Reset-Mail erhalten.
    user = User.where('LOWER(user_name) = ?', params[:username].to_s.downcase).first
    user.send_reset_information if user && !user.archived?

    render json: { success: true }, status: :ok
  end

  # POST /forgot_username
  # Schickt alle Benutzernamen, die an einer Adresse hängen, an diese Adresse.
  # Notwendig, weil die E-Mail-Adresse keine Login-Kennung ist: Wer nur seine
  # Adresse kennt, kommt sonst nicht einmal bis „Passwort vergessen“.
  #
  # Eine Adresse kann bewusst an mehreren Konten hängen (Vereins-Sammelpostfach,
  # Schiri- und Vereinsmanager-Konto derselben Person), deshalb listet die Mail
  # alle Namen auf statt nur den ersten.
  def forgot_username
    cookies.delete :user_id

    email = params[:email].to_s.strip.downcase
    unless email.match?(URI::MailTo::EMAIL_REGEXP)
      return render json: { success: false, message: 'Bitte gib eine gültige E-Mail-Adresse ein.' },
                    status: :unprocessable_entity
    end

    # Immer success, egal ob die Adresse existiert oder gerade die Wartezeit
    # greift – sonst wäre der Endpunkt ein Verzeichnis aller hinterlegten
    # Adressen. Aus demselben Grund ist auch kein 429 nach außen sichtbar.
    send_username_reminder(email) unless reminder_throttled?(email)

    render json: { success: true }, status: :ok
  end

  private

  def reminder_throttled?(email)
    cache_key = "forgot_username/#{Digest::SHA256.hexdigest(email)}"
    return true if Rails.cache.read(cache_key).present?

    Rails.cache.write(cache_key, true, expires_in: FORGOT_USERNAME_INTERVAL)
    false
  end

  def send_username_reminder(email)
    # Archivierte Konten bleiben außen vor, ihr Login ist ohnehin gesperrt.
    # Sind alle Konten der Adresse archiviert, geht gar keine Mail raus.
    user_names = User.not_archived.where('LOWER(email) = ?', email).order(:user_name).pluck(:user_name)
    return if user_names.empty?

    UserMailer.forgot_username(email, user_names).deliver_later
  end
end
