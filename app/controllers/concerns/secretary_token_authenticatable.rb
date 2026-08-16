module SecretaryTokenAuthenticatable
  extend ActiveSupport::Concern

  # Call in before_action chains: sets @secretary_link if a valid token is present.
  # When present, the user is not required to be logged in (authenticate_user is skipped).
  #
  # **Login ODER Link genügt, abgewiesen wird nur, wenn beides fehlt.** Vorher
  # entschied ein mitgeschickter Token allein: ließ er sich nicht auflösen, gab es
  # 401, unabhängig von `current_user`. Das ist kein Sonderfall, sondern der
  # Normalfall nach 72 Stunden (`GameDaySecretaryLink::VALIDITY`): Der
  # SecretaryTokenInterceptor im Frontend hängt einen einmal im sessionStorage
  # abgelegten Token an jede API-Anfrage und löscht ihn nirgends. Wer in dieser
  # Registerkarte einmal einen Sekretariats-Link geöffnet hatte, bekam danach
  # angemeldet 401 auf jedem Weg des Spielberichts
  # (`GamesController::SECRETARY_ACTIONS`, dort auch der Lesepfad `show_hidden`),
  # also mitten im laufenden Spiel.
  #
  # Dieselbe Konstruktion wie in
  # `ClubsController#authenticate_user_or_secretary_link` (#424). Unterschied nur
  # in der Ausgabe: Dort gibt es eine gemeinsame Meldung, hier zwei. Wer es mit
  # einem Link versucht hat, soll lesen, dass der Link nicht mehr gilt, und nicht
  # „nicht angemeldet".
  #
  # Eine echte Rangfolge zwischen beiden gibt es an genau einer Stelle, und die
  # ist unverändert: `secretary_or_current_user_id` trägt den angemeldeten
  # Menschen als Urheber ein, nicht den Aussteller des Links. Die Rechteprüfung
  # in `GamesController#can_edit_game?` wertet dagegen additiv aus, keiner der
  # beiden Wege sticht den anderen. Siehe #428.
  #
  # Ein unbrauchbarer Token verschwindet bei bestehender Sitzung bewusst
  # spurlos. `find_by_token` kann abgelaufen, zurückgezogen und gefälscht nicht
  # unterscheiden (alle drei enden in `nil`), und zurückgezogen ist der
  # Regelfall: `revoke_coverage_of` löscht den Link bei jeder Neuausgabe für
  # dieselbe Halle. Eine Meldung wäre also überwiegend eine Meldung über
  # legitime, ersetzte Links, und weil der Interceptor den Token nie löscht,
  # wäre sie eine Dauermeldung.
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
