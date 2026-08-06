# Wer darf für einen Spieltag einen Zugangslink erzeugen: Admin, der SBK des
# Spielbetriebs, der Vereinsmanager des ausrichtenden oder eines beteiligten
# Vereins und der Teammanager einer beteiligten Mannschaft.
#
# Herausgezogen aus GameDaySecretaryLinksController, weil die Overlay-Links
# dieselbe Frage beantworten müssen. Zwei Kopien derselben Rechteprüfung wären
# genau die Sorte Duplikat, die irgendwann auseinanderläuft.
module GameDayLinkAuthorization
  extend ActiveSupport::Concern

  private

  def authorize_vm_or_tm!
    ph = current_user.permission_hash
    go_id = @game_day.league.game_operation_id
    return if ph[:admin].present?
    return if ph[:sbk].present? && (ph[:sbk].include?(0) || ph[:sbk].include?(go_id))

    game_ids = @game_day.games.pluck(:home_team_id, :guest_team_id).flatten.compact
    club_id = @game_day.club_id

    vm_allowed = ph[:vm].present? && (ph[:vm].include?(club_id) ||
                   @game_day.games.any? do |g|
                     ph[:vm].intersection([g.home_team&.club_id, g.guest_team&.club_id].compact).present?
                   end)
    tm_allowed = ph[:tm].present? && ph[:tm].intersection(game_ids).present?

    return if vm_allowed || tm_allowed

    render json: { error: 'Nicht berechtigt.' }, status: :forbidden
  end

  def load_game_day
    @game_day = GameDay.find(params[:game_day_id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Spieltag nicht gefunden.' }, status: :not_found
  end
end
