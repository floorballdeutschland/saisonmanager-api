# frozen_string_literal: true

# Sperren in den Lizenzlisten einer Liga (#605).
#
# Bis dahin filterte League#build_license_items hart auf die Status `erteilt`
# und `beantragt`. Eine gesperrte Lizenz verschwand damit aus JEDER Lizenzliste
# -- auch aus der des Pokals, in dem der Spieler weiterhin spielen darf, und
# ohne die Zeile war die Sperre von der Lizenzverwaltung aus nicht erreichbar.
#
# Der angezeigte Status kommt deshalb aus zwei Quellen: dem Basis-Eintrag der
# Lizenzhistorie (was ohne Sperre gelten wuerde) und den aktiven Sperren, je
# Liga ausgewertet.
module LeagueLicenseSuspensions
  extend ActiveSupport::Concern

  class_methods do
    # Aktive Sperren der Spieler dieser Listen, je Spieler, in einer Abfrage.
    #
    # Bewusst OHNE Lazy-Ablauf: Player#expire_due_suspensions! wuerde in einem
    # GET ueber alle Ligen einer Saison schreiben. Noetig ist das hier nicht,
    # denn `covering` laesst eine abgelaufene Sperre gar nicht erst durch, und
    # der angezeigte Status kommt aus dem Basis-Eintrag der History und nicht
    # aus dem Sperr-Eintrag. Aufgeraeumt wird die History beim naechsten Blick
    # ins Spielerprofil.
    def license_suspensions(team_licenses)
      player_ids = team_licenses.each_value.flat_map { |players| players.map(&:id) }.uniq
      return {} if player_ids.empty?

      PlayerSuspension.active.covering(Date.current).where(player_id: player_ids).group_by(&:player_id)
    end
  end

  # Die Sperre, die auf einer Lizenzzeile liegt -- so knapp, dass die Liste sie
  # anzeigen und aufheben kann, ohne das Spielerprofil zu oeffnen.
  def suspension_item(suspension)
    return nil if suspension.blank?

    {
      id: suspension.id,
      scope_kind: suspension.scope_kind,
      scope_summary: suspension.scope_summary,
      valid_from: suspension.valid_from,
      valid_until: suspension.valid_until,
      games_total: suspension.games_total,
      games_served: suspension.games_served,
      remaining_games: suspension.remaining_games,
      reason: suspension.reason
    }
  end
end
