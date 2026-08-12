# Logo der Liga, etwa das Zeichen der 1. Floorball-Bundesliga Herren.
#
# Nicht zu verwechseln mit dem Banner nebenan: Das ist eine Werbefläche im
# Format 6:1 mit Ziellink. Dies hier ist ein Erkennungszeichen und steht
# stellvertretend für den Wettbewerb, etwa in den Livestream-Einblendungen.
#
# Fallback auf den Landesverband, weil es nur dort ein weiteres Logo gibt: Ein
# Spielbetrieb hat keines, `GameOperation#meta_hash` reicht das des
# Landesverbands durch. Die Kette ist also bewusst nur zwei Stufen lang.
module LeagueLogo
  extend ActiveSupport::Concern

  included do
    has_one_attached :logo
  end

  def logo_url
    return nil unless logo.attached?

    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true)
  end

  # Das anzuzeigende Logo samt Herkunft. Die Herkunft steht dabei, damit eine
  # Anzeige entscheiden kann, ob sie das Verbandslogo überhaupt will: Im
  # Overlay ist ein Ligazeichen erwünscht, ein Landesverbandslogo an derselben
  # Stelle wäre eher irreführend.
  def resolved_logo
    return { logo_url: logo_url, logo_source: 'league' } if logo.attached?

    sa = game_operation&.state_association
    return { logo_url: sa.logo_url, logo_source: 'state_association' } if sa&.logo&.attached?

    { logo_url: nil, logo_source: nil }
  end
end
