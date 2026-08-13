# Wer darf für einen Spieltag einen Zugangslink erzeugen: Admin, der SBK des
# Spielbetriebs, der Vereinsmanager des ausrichtenden oder eines beteiligten
# Vereins und der Teammanager einer beteiligten Mannschaft.
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

    team_ids = game_day.games.flat_map { |g| [g.home_team_id, g.guest_team_id] }.compact
    return true if ph[:tm].present? && ph[:tm].intersection(team_ids).present?

    return false if ph[:vm].blank?
    return true if ph[:vm].include?(game_day.club_id)

    game_day.games.any? do |g|
      ph[:vm].intersection([g.home_team&.club_id, g.guest_team&.club_id].compact).present?
    end
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
