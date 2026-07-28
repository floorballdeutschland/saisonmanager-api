class SessionsController < ApplicationController
  skip_before_action :authenticate_user, only: %i[login logout lost_password]
  skip_before_action :verify_authenticity_token, only: %i[login logout lost_password]

  # Hinweis für Nutzer, die ihre E-Mail-Adresse ins Login-Feld tippen. Die
  # Entscheidung fällt rein syntaktisch am @ und ohne Datenbankzugriff, damit
  # sich daraus nicht ablesen lässt, welche Adressen im System existieren.
  EMAIL_LOGIN_HINT = 'Bitte melde dich mit deinem Benutzernamen an, nicht mit deiner E-Mail-Adresse.'.freeze

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
end
