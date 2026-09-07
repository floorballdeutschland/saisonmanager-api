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
    # Zur Begruendung, warum hier nichts ablaeuft, siehe
    # PlayerSuspension.active_by_player -- dieselbe Tabelle lesen auch die
    # Lizenzlisten des Spieltags und die Antragsuebersicht des Vereins.
    def license_suspensions(team_licenses)
      PlayerSuspension.active_by_player(
        team_licenses.each_value.flat_map { |players| players.map(&:id) }
      )
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
