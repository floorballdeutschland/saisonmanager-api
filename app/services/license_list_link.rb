# frozen_string_literal: true

# Signierter Link auf die Lizenzlisten der beiden Mannschaften eines Spiels
# (PublicLicenseListController). Der Link trägt keine Anmeldung, sondern nur ein
# Token, deshalb ist seine Gültigkeit knapp gehalten.
#
# Die Gültigkeit hängt am SPIEL, nicht am Versandzeitpunkt. Vorher lief das
# Token 72 Stunden nach dem Veröffentlichen der Ansetzung ab: Wurde drei Wochen
# vor dem Spiel angesetzt, war der Link längst tot, wenn der Schiedsrichter ihn
# in der Halle gebraucht hätte. Jetzt endet er am Ende des Tages NACH dem Spiel.
# Damit sind Expresslizenzen bis zum Anpfiff sichtbar, und danach kommt niemand
# mehr an die Namenslisten.
class LicenseListLink
  # Spieltagsdaten sind lokale Daten (`game_days.date` ist eine Textspalte ohne
  # Zeitzone), die Anwendung läuft mangels `config.time_zone` in UTC. Der Ablauf
  # wird deshalb im Kalender des Spielbetriebs gerechnet.
  ZONE = ActiveSupport::TimeZone['Europe/Berlin'].freeze

  attr_reader :game

  def initialize(game)
    @game = game
  end

  # Ende des Tages nach dem Spiel, oder nil, wenn das Spieltagsdatum fehlt bzw.
  # unlesbar ist: ohne Datum gibt es keine spielbezogene Gültigkeit.
  def expires_at
    return @expires_at if defined?(@expires_at)

    date = game.game_date
    @expires_at = date && ZONE.parse(date.next_day.to_s).end_of_day
  end

  # False für Spiele ohne lesbares Datum und für Spiele, die schon länger als
  # einen Tag vorbei sind. Ein Token mit negativer Restlaufzeit wäre beim ersten
  # Aufruf abgelaufen, und dann gehört gar kein Link in die Mail.
  def available?
    expires_at.present? && expires_at > Time.current
  end

  def url
    return nil unless available?

    "#{FrontendUrl.base}/lizenzliste?token=#{CGI.escape(token)}"
  end

  private

  def token
    Rails.application.message_verifier('license_list').generate(
      { game_id: game.id, expires_at: expires_at.iso8601 },
      expires_in: expires_at - Time.current
    )
  end
end
