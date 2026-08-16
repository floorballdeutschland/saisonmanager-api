module SecretaryTokenAuthenticatable
  extend ActiveSupport::Concern

  # Call in before_action chains: sets @secretary_link if a valid token is present.
  # When present, the user is not required to be logged in (authenticate_user is skipped).
  #
  # **Der Login hat Vorrang, der Token ist der Ersatzweg.** Vorher entschied ein
  # mitgeschickter Token allein: ließ er sich nicht auflösen, gab es 401,
  # unabhängig von `current_user`. Das ist kein Sonderfall, sondern der Normalfall
  # nach 72 Stunden (`GameDaySecretaryLink::VALIDITY`): Der
  # SecretaryTokenInterceptor im Frontend hängt einen einmal im sessionStorage
  # abgelegten Token an JEDE Anfrage und löscht ihn nirgends. Wer in dieser
  # Registerkarte einmal einen Sekretariats-Link geöffnet hatte, bekam danach
  # angemeldet 401 auf jedem Schreibweg des Spielberichts
  # (`GamesController::SECRETARY_ACTIONS`), also mitten im laufenden Spiel.
  #
  # Abgewiesen wird deshalb nur, wenn beide Wege versagen. Die Meldung richtet
  # sich nach dem Grund: Wer es mit einem Link versucht hat, soll lesen, dass der
  # Link nicht mehr gilt, und nicht „nicht angemeldet".
  #
  # Gleiche Reihenfolge wie in `ClubsController#authenticate_user_or_secretary_link`
  # (#424) und in `secretary_or_current_user_id` unten. Siehe #428.
  def authenticate_with_secretary_token_or_user
    raw_token = request.headers['X-Secretary-Token'] || params[:secretary_token]
    @secretary_link = GameDaySecretaryLink.find_by_token(raw_token) if raw_token.present?
    return if current_user || @secretary_link

    if raw_token.present?
      render json: { message: 'Spielsekretariats-Link ungültig oder abgelaufen.' }, status: :unauthorized
    else
      render json: { success: false, message: 'Not authenticated' }, status: 401
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

  # Game is within scope of the secretary token? Ein Link deckt seit der
  # hallenweiten Ausgabe mehrere Spieltage ab (mehrere Ligen am selben Tag in
  # derselben Halle), daher Mengenprüfung statt Gleichheit.
  def secretary_token_permits_game?(game)
    return false unless @secretary_link

    @secretary_link.covers_game_day?(game.game_day_id)
  end
end
