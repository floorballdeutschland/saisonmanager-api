# Zentrale Quelle für die Basis-URL des öffentlichen Frontends. Wird in Mailer-,
# Controller- und Model-Code für alle nutzergerichteten Links (Passwort-Reset,
# Bestätigungslinks, Spielbericht-Uploads …) verwendet.
#
# Auflösungsreihenfolge:
#   1. ENV['FRONTEND_BASE_URL'] – auf Staging (saisonmanager.dev) gesetzt, damit
#      Links dort NICHT auf das Produktivsystem zeigen.
#   2. In Produktion (ohne ENV) das Produktiv-Frontend.
#   3. Sonst (development/test) der lokale ng-serve-Port.
#
# Hintergrund: Staging läuft mit RAILS_ENV=production, deshalb reicht eine
# Rails.env.production?-Abfrage nicht aus, um Prod von Staging zu unterscheiden.
module FrontendUrl
  PRODUCTION_URL = 'https://saisonmanager.de'.freeze
  LOCAL_URL = 'http://localhost:4200'.freeze

  def self.base
    ENV['FRONTEND_BASE_URL'].presence ||
      (Rails.env.production? ? PRODUCTION_URL : LOCAL_URL)
  end

  # Reiner Host ohne Schema, z. B. für Anzeige-Text in Footer-Links.
  def self.host
    base.sub(%r{\Ahttps?://}, '')
  end
end
