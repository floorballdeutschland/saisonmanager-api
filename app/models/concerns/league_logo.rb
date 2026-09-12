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

    # Proxy-Route statt Redirect-Route, damit der Browser das Logo behalten
    # kann.
    #
    # Nicht die erste URL war das Problem: rails_blob_path lieferte
    # /api/storage/blobs/redirect/<signed_id>/..., und diese signed_id ist
    # bereits dauerhaft (ActiveStorage.urls_expire_in ist nil). Der Aufwand
    # steckte im zweiten Sprung. Der RedirectController macht zweierlei:
    #
    #   expires_in ActiveStorage.service_urls_expire_in   # 5 Minuten
    #   redirect_to @blob.url(...)                        # Ziel-URL, 5 Minuten
    #
    # Die Weiterleitung selbst darf der Browser also nur fuenf Minuten
    # behalten, und ihr Ziel -- die Disk-URL mit eigenem exp-Zeitstempel --
    # ebenfalls. Nach fuenf Minuten holt er die Weiterleitung neu, bekommt
    # eine frisch signierte Ziel-URL und laedt die Datei erneut, weil die URL
    # Teil seines Cache-Schluessels ist. Zwei Rails-Requests je Wappen, alle
    # fuenf Minuten, fuer ein Bild das sich im Jahr vielleicht einmal aendert.
    #
    # Am 1. Bundesliga-Spieltag (12.09.2026) waren dadurch 239 von 411
    # Requests Logo-Verkehr: 123 Auslieferungen und rund 116 Weiterleitungen.
    #
    # Die Proxy-Route hat keinen Zwischenschritt, und der ProxyController
    # antwortet mit http_cache_forever public: true. Damit gibt es genau eine
    # stabile URL, die der Browser dauerhaft behaelt.
    #
    # BEWUSST NUR FUER LOGOS UND BANNER -- aber NICHT, weil die Redirect-Route
    # einen Zugriffsschutz haette. Sie hat keinen: Ihre signed_id ist genauso
    # dauerhaft (siehe oben), und der RedirectController signiert bei jedem
    # Aufruf eine frische Disk-URL. Wer einen rails_blob_url auf ein
    # Lizenzdokument einmal besitzt, holt sich das Dokument beliebig oft und
    # beliebig lange. Keine der beiden Routen ist authentifiziert: Beide
    # Controller erben von ActiveStorage::BaseController, nicht von
    # ApplicationController -- weder authenticate_user noch
    # authenticate_public_request laufen dort je.
    #
    # Vertrauliche Anlagen (Lizenzdokumente, Spielberichtsscans,
    # Schiedsrichterberichte, Kursimport-CSV, Dokumentvorlagen) bleiben aus
    # zwei anderen Gruenden unangetastet: Es gibt keinen Grund, die
    # Angriffsflaeche ohne Not zu vergroessern, und http_cache_forever wuerde
    # ihnen ein Cache-Control ueber hundert Jahre mitgeben -- eine Kopie in
    # jedem Browser- und Zwischenspeicher, die niemand mehr einsammelt.
    #
    # Deshalb wird je Aufrufstelle umgestellt und nicht global. Ein
    # config.active_storage.resolve_model_to_route = :rails_storage_proxy
    # waere eine Zeile gewesen und haette die Lizenz-Controller
    # mitgerissen, weil direct :rails_blob denselben Schalter liest.
    Rails.application.routes.url_helpers.rails_storage_proxy_path(logo, only_path: true)
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
