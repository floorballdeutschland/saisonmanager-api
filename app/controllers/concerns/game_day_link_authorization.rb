# Wer darf für einen Spieltag einen Zugangslink erzeugen: Admin, der SBK des
# Spielbetriebs, der Vereinsmanager des ausrichtenden Vereins und der
# Teammanager einer an diesem Spieltag spielenden Mannschaft, deren Verein
# ausrichtet. Die zweite Bedingung ist nicht redundant: Der Teammanager der
# zweiten Mannschaft des Ausrichters kommt an einen Spieltag ohne seine
# Mannschaft nicht heran.
#
# Die Linie endet am Ausrichter, nicht bei „irgendwie beteiligt": Am
# Sekretariatstisch sitzt der Ausrichter, und gestreamt wird ebenfalls aus
# seiner Halle. Vorher kam auch der Gastverein an beides heran und sah dadurch
# in der Sekretariats-Übersicht fremde Spieltage (api#551).
#
# Für den Overlay-Zugang ist das bewusst enger als das Recht am Spielbericht
# selbst: `Game#user_permissions` gibt dem Gastverein weiter
# `pregame_edit_guest` für seine eigene Aufstellung. Wer seinen Teil des
# Berichts führen darf, darf damit nicht automatisch die Bühnengrafik des
# Ausrichters bespielen.
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

    # `game_days.club_id` ist nullable, und der Spielplan-Import quittiert einen
    # fehlenden Ausrichter nur mit einer Warnung (LeaguesController), legt den
    # Spieltag also an. Ohne Ausrichter gibt es hier bewusst keinen Zugang: Wer
    # den Link braucht, trägt den Ausrichter nach, und das kann jeder jederzeit.
    # Ein Ersatz aus den Heimmannschaften wäre an einem Turniertag ohnehin nicht
    # "der Ausrichter", sondern jeder Verein mit Heimspiel – für eine
    # Zusatzfunktion die falsche Aufweichung der Regel.
    host_club_id = game_day.club_id
    return false if host_club_id.blank?

    return true if ph[:vm].present? && ph[:vm].include?(host_club_id)

    ph[:tm].present? && own_teams(game_day).any? { |team| team.all_club_ids.include?(host_club_id) }
  end

  # Die Mannschaften dieses Spieltags, die der/die Angemeldete als Teammanager:in
  # betreut. Verglichen wird anschließend in may_manage_game_day_link? über
  # `all_club_ids`: Eine Spielgemeinschaft, die unter ihrem Partnerverein
  # ausrichtet, fiele sonst durch, obwohl sie am eigenen Tisch sitzt.
  def own_teams(game_day)
    managed_team_ids = permissions[:tm]

    game_day.games
            .flat_map { |g| [g.home_team, g.guest_team] }
            .compact
            .select { |team| managed_team_ids.include?(team.id) }
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
