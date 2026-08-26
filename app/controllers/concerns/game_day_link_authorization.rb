# Wer darf für einen Spieltag einen Zugangslink erzeugen: Admin, der SBK des
# Spielbetriebs, der Vereinsmanager des ausrichtenden Vereins und der
# Teammanager einer Mannschaft, deren Verein ausrichtet.
#
# Die Linie endet am Ausrichter, nicht bei „irgendwie beteiligt": Am
# Sekretariatstisch sitzt der Ausrichter, und gestreamt wird ebenfalls aus
# seiner Halle. Bis 1.98.x kam auch der Gastverein an beides heran und sah
# dadurch in der Sekretariats-Übersicht fremde Spieltage (api#551).
#
# Herausgezogen, weil zwei Funktionen dieselbe Frage beantworten müssen: der
# Sekretariatslink und der Overlay-Zugang für die Livestream-Grafiken. Zwei
# Kopien derselben Rechteprüfung wären genau die Sorte Duplikat, die
# auseinanderläuft, sobald eine Rolle dazukommt.
module GameDayLinkAuthorization
  extend ActiveSupport::Concern

  private

  # permission_hash ist nicht memoisiert und zieht bei jedem Aufruf unter
  # anderem alle Liga-IDs der Saison. In der Spieltags-Übersicht wird je
  # Spieltag geprüft, das wären sonst schnell 50 Neuberechnungen in einer
  # einzigen Anfrage.
  def permissions
    @permissions ||= current_user.permission_hash
  end

  # `game_days.league_id` ist nullable, deshalb der sichere Zugriff auf die
  # Liga: Ein Spieltag ohne Liga darf die Prüfung nicht mit einem 500 beenden.
  def may_manage_game_day_link?(game_day)
    ph = permissions
    return true if ph[:admin].present?

    go_id = game_day.league&.game_operation_id
    return true if ph[:sbk].present? && (ph[:sbk].include?(0) || ph[:sbk].include?(go_id))

    host_club_ids = hosting_club_ids(game_day)
    return false if host_club_ids.empty?

    return true if ph[:vm].present? && ph[:vm].intersect?(host_club_ids)

    ph[:tm].present? && own_teams(game_day).any? { |team| team.all_club_ids.intersect?(host_club_ids) }
  end

  # Der ausrichtende Verein.
  #
  # `game_days.club_id` ist nullable und wird bei `0` aktiv auf `nil` gesetzt
  # (GameDay#normalize_blank_references); der Spielplan-Import legt Spieltage
  # bewusst ohne Halle und ohne Ausrichter an. Ohne Rückfall bliebe für sie
  # niemand übrig, der den Link ausgeben kann, und die Sekretariats-Übersicht
  # ist der einzige Weg des Vereins dorthin.
  #
  # Der Rückfall nimmt die Vereine der Heimmannschaften, also den faktischen
  # Ausrichter. Ein Gastverein kommt darüber nicht herein.
  def hosting_club_ids(game_day)
    return [game_day.club_id] if game_day.club_id.present?

    game_day.games.filter_map { |g| g.home_team&.club_id }.uniq
  end

  # Die Mannschaften dieses Spieltags, die der/die Angemeldete als Teammanager:in
  # betreut. Verglichen wird anschließend über `all_club_ids`: Eine
  # Spielgemeinschaft, die unter ihrem Partnerverein ausrichtet, fiele sonst
  # durch, obwohl sie am eigenen Tisch sitzt.
  def own_teams(game_day)
    tm_team_ids = permissions[:tm]

    game_day.games
            .flat_map { |g| [g.home_team, g.guest_team] }
            .compact
            .select { |team| tm_team_ids.include?(team.id) }
  end

  def authorize_game_day_link!
    return if may_manage_game_day_link?(@game_day)

    render json: { error: 'Nicht berechtigt.' }, status: :forbidden
  end

  def load_game_day
    @game_day = GameDay.find(params[:game_day_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Spieltag nicht gefunden.' }, status: :not_found
  end
end
