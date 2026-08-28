# frozen_string_literal: true

# Anpfiff eines Spiels als echter Zeitpunkt.
#
# Eigene Klasse, weil die Rechnung zwei Fallen enthält, die an jeder Kopie neu
# zuschlagen würden:
#
# 1. `game_days.date` ist eine TEXTSPALTE mit lokalem Datum ohne Zeitzone, und
#    die Anwendung läuft mangels `config.time_zone` in UTC. Aufgelöst wird
#    deshalb im Kalender des Spielbetriebs (Europe/Berlin) und nicht in der
#    Anwendungszone -- abends weichen beide um zwei Stunden ab.
# 2. Das Datum wird strikt im Format der Spalte geparst. `Time.zone.parse` über
#    den Gesamtstring macht aus einem unbrauchbaren Datum plus „10:00"
#    stillschweigend HEUTE 10:00 Uhr und legt das Fenster damit auf einen frei
#    erfundenen Zeitpunkt.
#
# Genutzt von RefereeFeedbackWindow (Abgabefenster des Vereins-Feedbacks) und
# RefereeObservationReminder (Erinnerung an den Schiedsrichtercoach).
module GameKickoff
  ZONE = ActiveSupport::TimeZone['Europe/Berlin'].freeze

  # Heute, aus Sicht des Spielbetriebs.
  def self.today
    ZONE.today
  end

  # Anpfiff in lokaler Zeit, oder nil, wenn kein brauchbares Spieltagsdatum
  # vorliegt. Fehlt nur die Uhrzeit, wird vom Tagesbeginn gerechnet, damit ein
  # Spiel ohne gepflegte Startzeit nicht die ganze Rechnung reißt.
  def self.at(game)
    date = game&.game_day&.date
    return nil if date.blank?

    day = Date.strptime(date.to_s, '%Y-%m-%d')
    ZONE.parse("#{day} #{game.start_time}".strip)
  rescue ArgumentError, TypeError
    nil
  end
end
