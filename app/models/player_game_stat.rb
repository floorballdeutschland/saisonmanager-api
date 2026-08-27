# Aggregat der Spielerdaten je (Spieler, Liga, Team), geschrieben vom naechtlichen
# Lauf PlayerStats::Refresher (rake player_stats:refresh).
#
# Bewusst ohne Rechen-Code: Was in den Zeilen steht, entscheidet der Refresher, wie
# sie gelesen werden, der Admin::PlayerStatisticsController. Das Modell haelt nur die
# Scopes, die beide teilen.
class PlayerGameStat < ApplicationRecord
  belongs_to :player

  # nil heisst „kein Vereinsfilter" (bundesweiter Scope), nicht „keine Vereine".
  # Ein `where(club_id: nil)` waere hier der teure Unterschied zwischen „alle
  # Spielerdaten" und „gar keine".
  scope :for_clubs, ->(club_ids) { club_ids.nil? ? all : where(club_id: club_ids) }
end
