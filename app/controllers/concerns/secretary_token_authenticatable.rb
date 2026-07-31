module SecretaryTokenAuthenticatable
  extend ActiveSupport::Concern

  # Call in before_action chains: sets @secretary_link if a valid token is present.
  # When present, the user is not required to be logged in (authenticate_user is skipped).
  def authenticate_with_secretary_token_or_user
    raw_token = request.headers['X-Secretary-Token'] || params[:secretary_token]
    if raw_token.present?
      @secretary_link = GameDaySecretaryLink.find_by_token(raw_token)
      unless @secretary_link
        render json: { message: 'Spielsekretariats-Link ungültig oder abgelaufen.' }, status: :unauthorized
        return
      end
    else
      render json: { success: false, message: 'Not authenticated' }, status: 401 unless current_user
    end
  end

  # Wie authenticate_with_secretary_token_or_user, aber ohne Zwang: setzt
  # @secretary_link, wenn ein gültiger Token mitkommt, und lässt die Anfrage
  # sonst unangetastet. Für Actions, die auch ohne Token erreichbar bleiben
  # müssen (die öffentliche Spielseite per API-Key), mit Token aber mehr zeigen.
  #
  # Ein ungültiger Token wird bewusst ignoriert statt abgewiesen: die Action ist
  # ohnehin öffentlich, ein 401 würde die Seite nur unbenutzbar machen.
  def set_secretary_link_if_present
    raw_token = request.headers['X-Secretary-Token'] || params[:secretary_token]
    return if raw_token.blank?

    @secretary_link = GameDaySecretaryLink.find_by_token(raw_token)
  end

  # Returns the user ID to record as the author of changes when using secretary token.
  def secretary_or_current_user_id
    current_user&.id || @secretary_link&.created_by_id
  end

  # Game is within scope of the secretary token?
  def secretary_token_permits_game?(game)
    @secretary_link&.game_day_id == game.game_day_id
  end
end
