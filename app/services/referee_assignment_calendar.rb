# frozen_string_literal: true

require 'icalendar'
require 'icalendar/tzinfo'

# Kalenderdatei (ICS) für eine veröffentlichte Ansetzung, als Anhang der
# Ansetzungsmail. Der Empfänger übernimmt den Termin mit einem Klick in seinen
# Kalender, statt Datum, Anpfiff und Halle aus der Mail abzutippen.
#
# METHOD:PUBLISH, nicht REQUEST: Eine Einladung (REQUEST) würde Zu- und Absagen
# an das Ansetzungs-Postfach zurückschicken, das niemand auswertet. PUBLISH ist
# genau das gewünschte „hier ist ein Termin, trag ihn ein".
#
# Die UID hängt an Spiel und Person und ist über Umbesetzungen hinweg stabil:
# Eine erneut verschickte Datei aktualisiert damit den vorhandenen Termin statt
# einen zweiten anzulegen. SEQUENCE muss dafür mitzählen, sonst verwerfen
# Kalender-Programme die neue Fassung.
#
# Anders als die Kalender-Abos (IcalRenderable) setzt diese Datei die TZID
# ausdrücklich und legt die passende VTIMEZONE bei. Ein Anhang wird oft in einem
# Kalender geöffnet, der nicht in Europe/Berlin steht; ohne Zone wäre der
# Anpfiff eine „floating time" und landete beim Empfänger auf der falschen
# Uhrzeit.
class RefereeAssignmentCalendar
  TIMEZONE = 'Europe/Berlin'
  PRODID = '-//Floorball Deutschland//Saisonmanager//DE'

  # Ohne Anpfiffzeit wird ein ganztägiger Termin erzeugt: Das Datum steht fest,
  # nur die Uhrzeit fehlt noch. Ein Termin auf dem richtigen Tag ist nützlicher
  # als gar keiner. Beim Abo (IcalRenderable) fallen solche Spiele heraus, dort
  # ginge ein ganztägiger Eintrag je Spiel aber auch als Dauerzustand durch.
  def initialize(game, recipient:, role: :referee, officials: nil, coach_name: nil,
                 club_contact_email: nil, notes: nil)
    @game = game
    @recipient = recipient
    @role = role
    @officials = officials
    @coach_name = coach_name
    @club_contact_email = club_contact_email
    @notes = notes
  end

  # nil, wenn das Spieltagsdatum fehlt oder unlesbar ist (`game_days.date` ist
  # eine Textspalte). Ein Termin ohne Datum hat keinen Inhalt; die Mail geht dann
  # ohne Anhang raus statt gar nicht.
  def to_ical
    return nil if game_date.nil?

    calendar = ::Icalendar::Calendar.new
    calendar.prodid = PRODID
    calendar.add_timezone(TZInfo::Timezone.get(TIMEZONE).ical_timezone(timezone_reference))
    calendar.add_event(event)
    calendar.ip_method = 'PUBLISH'
    calendar.to_ical
  end

  def filename
    "ansetzung-#{@game.game_number.presence || @game.id}.ics"
  end

  private

  def event
    ::Icalendar::Event.new.tap do |event|
      apply_times(event)
      event.uid = "sm_referee_assignment_#{@game.id}_#{@role}_#{@recipient.id}@saisonmanager.org"
      # Wie Game#ical: der Zeitstempel des Versands als monoton wachsende
      # Versionsnummer des Termins.
      event.sequence = Time.now.to_i
      event.summary = summary
      event.description = description
      event.location = location if location.present?
      event.url = @game.url
      event.ip_class = 'PRIVATE'
      event.status = 'CONFIRMED'
    end
  end

  def apply_times(event)
    if @game.start_date
      event.dtstart = ::Icalendar::Values::DateTime.new(@game.start_date, 'tzid' => TIMEZONE)
      event.dtend = ::Icalendar::Values::DateTime.new(@game.end_date, 'tzid' => TIMEZONE)
    else
      # Ganztägig: DTEND ist bei DATE-Werten exklusiv, also der Folgetag.
      event.dtstart = ::Icalendar::Values::Date.new(game_date)
      event.dtend = ::Icalendar::Values::Date.new(game_date.next_day)
    end
  end

  def summary
    prefix = @role == :coach ? 'SR-Coach' : 'SR'
    "#{prefix}: #{@game.home_team&.name} vs. #{@game.guest_team&.name}"
  end

  # Alles, was der Schiedsrichter am Spieltag im Kalender braucht, ohne die Mail
  # nochmal zu suchen. Leere Angaben fallen heraus statt als „–" mitzulaufen.
  def description
    lines = []
    lines << "Liga: #{@game.game_day.league&.name}" if @game.game_day.league&.name.present?
    lines << "Spielnummer: #{@game.game_number}" if @game.game_number.present?
    lines << (@role == :coach ? "Schiedsrichter/innen: #{@officials}" : "Schiri-Partner/in: #{@officials}") if @officials.present?
    lines << "Schiedsrichtercoach/in: #{@coach_name}" if @coach_name.present?
    lines << "Kontakt Ausrichter: #{@club_contact_email}" if @club_contact_email.present?
    if @notes.present?
      lines << ''
      lines << 'Zusätzliche Spielinformationen:'
      lines << @notes
    end
    lines << ''
    lines << "Spiel im Saisonmanager: #{@game.url}"
    lines.join("\n")
  end

  def location
    arena = @game.game_day.arena
    return nil if arena.nil?

    [arena.name, arena.address].compact_blank.join(', ')
  end

  def game_date
    return @game_date if defined?(@game_date)

    @game_date = @game.game_date
  end

  # `ical_timezone` braucht einen Zeitpunkt, um die an diesem Datum gültige
  # Sommer-/Winterzeit-Regel zu bestimmen (siehe IcalRenderable).
  def timezone_reference
    @game.start_date || ActiveSupport::TimeZone[TIMEZONE].parse(game_date.to_s)
  end
end
