# frozen_string_literal: true

# Wer darf die Spielerliste EINES Vereins sehen?
#
# Die Regel gab es bisher nur einmal, als Rumpf in PlayersController#vm_players_index.
# Mit der Spielerdaten-Rangliste (Issue #465) gibt es einen zweiten Leser derselben
# Liste, und zwei Fassungen derselben Rechteregel driften auseinander -- genau so
# entstand der Widerspruch beim Heimatverein (siehe Player#home_club_entry). Deshalb
# hier, geteilt von beiden Controllern.
#
# Zustaendig ist, wer den Verein verwaltet oder verantwortet:
#   - Admin (bundesweit oder regional)
#   - SBK, in deren Spielbetrieb der Verein seinen Heimat-Spielbetrieb hat
#   - Vereinsmanager genau dieses Vereins
#   - Teammanager einer Mannschaft dieses Vereins (auch ueber eine Spielgemeinschaft)
#
# Bewusst NICHT dasselbe wie der Zugriff auf ein einzelnes Profil
# (`can_manage_player?`): Der haengt am Heimatverein der Person, diese Regel am Verein.
module ClubListAccess
  extend ActiveSupport::Concern

  private

  def club_list_access?(ph, club_id)
    sbk_ok = ph[:sbk].present? &&
             (ph[:sbk].include?(0) || derive_club_ids_for_go(ph[:sbk]).include?(club_id))

    ph[:admin].present? || sbk_ok ||
      (ph[:vm].present? && ph[:vm].include?(club_id)) ||
      tm_can_access_club?(ph, club_id)
  end

  def derive_club_ids_for_go(go_ids)
    Club.home_clubs_of(go_ids).pluck(:id)
  end

  def tm_can_access_club?(ph, club_id)
    tm_club_ids(ph).include?(club_id)
  end

  # Wie #user_permission_hash je Anfrage nur einmal: Ueber die Spielersuche kaeme
  # sonst je Treffer eine Team-Abfrage samt all_club_ids dazu. Der Cache sitzt
  # am Konto (User#tm_club_ids), weil `Club#user_permissions` dieselbe Liste
  # braucht -- zwei Fassungen derselben Frage laufen auseinander. `ph` bleibt
  # als Parameter stehen, damit die Aufrufer unveraendert bleiben; er stammt
  # ohnehin aus genau diesem Konto.
  def tm_club_ids(_ph)
    current_user.tm_club_ids
  end
end
