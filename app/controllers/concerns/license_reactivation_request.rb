# frozen_string_literal: true

# Der Antrag des Vereins, der eine Lizenz „ungültig wg. Transfer" reaktiviert
# (PlayersController#request_license, siehe Player#reactivatable_license_for).
#
# Ausgelagert, weil PlayersController an seiner Metrics/ClassLength-Grenze
# liegt und request_license an seiner Komplexitaetsgrenze.
module LicenseReactivationRequest
  extend ActiveSupport::Concern

  private

  # Ergebnis-Symbol wie in request_license. Geschrieben wird nur bei :ok;
  # jede Absage kommt vor der ersten Aenderung am Profil.
  def reactivation_request(player, license, team, ph, express_requested, guardian_email, minor_consent_at)
    # Admins bleiben wie beim Antrag von der Mitgliedschaftspruefung
    # ausgenommen, damit Korrekturen an Altdaten moeglich sind.
    return :not_returned if ph[:admin].blank? && !player.returned_after_transfer?(license, team)
    # Kostenfrei heisst auch ohne Expresszuschlag. Still ignorieren waere
    # schlechter: Der Verein haette das Haekchen gesetzt und wartete auf eine
    # Eilbearbeitung, die niemand ausloest.
    return :reactivation_express if express_requested

    player.request_reactivation!(license, current_user.id, guardian_email:, minor_consent_at:)
    player.save ? :ok : :save_failed
  end
end
