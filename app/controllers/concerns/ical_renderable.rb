require 'icalendar'
require 'icalendar/tzinfo'

# Baut die ICS-Antwort für Kalender-Abos (Mannschaft, Liga, Einzelspiel).
#
# Vorher stand dieselbe Folge dreimal in Teams-, Leagues- und GamesController.
# Der nil-Absturz unten trat deshalb auch dreifach auf, und ein Fix an einer
# Stelle hätte die beiden anderen stehen gelassen.
module IcalRenderable
  extend ActiveSupport::Concern

  ICAL_TIMEZONE = 'Europe/Berlin'.freeze

  private

  # Rendert die übergebenen Spiele als Kalender.
  #
  # Spiele ohne Anpfiffzeit haben kein `dtstart` (siehe Game#ical) und gehören
  # nicht in ein Abo: ein Termin ohne Zeitpunkt ist für den Kalender nutzlos.
  # Sie fallen hier heraus, statt als leerer Eintrag mitzulaufen.
  def render_ical(games)
    ical = ::Icalendar::Calendar.new
    events = Array(games).map(&:ical).select(&:dtstart)
    events.each { |event| ical.add_event(event) }

    # Nur mit mindestens einem Termin: `tz.ical_timezone` braucht einen
    # Zeitpunkt, um die zu diesem Datum gültige Sommer-/Winterzeit-Regel zu
    # bestimmen. Auf einem leeren Kalender lief das auf `nil.dtstart` und
    # damit auf HTTP 500 (Sentry SAISONMANAGER-29) – und zwar für jede
    # Mannschaft, deren Spielplan noch keine Termine hat, also am
    # Saisonanfang für alle.
    if events.any?
      tz = TZInfo::Timezone.get(ICAL_TIMEZONE)
      ical.add_timezone tz.ical_timezone(events.first.dtstart)
    end

    ical.append_custom_property('METHOD', 'REQUEST')
    ical.publish

    # Ein Abo ruft unbeaufsichtigt und dauerhaft ab, und der Endpunkt verlangt
    # keinen API-Schlüssel – es gibt also keine Grenze je Schlüssel, die den
    # Aufwand deckelt. Eine Stunde ist reichlich: Kalender-Programme gleichen
    # ohnehin höchstens stündlich ab, und ein Spielplan ändert sich nicht im
    # Minutentakt. `public`, weil die Antwort für alle gleich ausfällt – anders
    # als bei den Spielplan-Abrufen, wo delay_live_scores sie je Schlüssel und
    # Sitzung variiert und ein geteilter Cache die Varianten mischen würde.
    expires_in 1.hour, public: true

    # Kalender-Programme entscheiden am Content-Type, ob sie ein Abo annehmen;
    # `render plain:` schickte text/plain und lieferte bei manchen Clients nur
    # eine angezeigte Textdatei.
    render plain: ical.to_ical, content_type: 'text/calendar'
  end
end
