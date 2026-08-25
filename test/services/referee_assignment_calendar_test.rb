require 'test_helper'

# Die Ansetzungsmail trägt den Termin als ICS-Datei bei, damit der Schiedsrichter
# ihn mit einem Klick in seinen Kalender übernimmt statt Datum, Anpfiff und Halle
# abzutippen.
class RefereeAssignmentCalendarTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @arena = create(:arena, name: 'Sporthalle Nord', street: 'Hallenweg', housenumber: '3',
                            postcode: '12345', city: 'Beispielstadt')
    @league = create(:league, name: 'Testliga', game_operation: create(:game_operation, :national))
    @club = create(:club, contact_email: 'ausrichter@example.de')
    @game_day = create(:game_day, league: @league, arena: @arena, club: @club, date: '2026-03-07')
    @game = create(:game, game_day: @game_day, start_time: '14:00', game_number: '4711',
                          home_team: create(:team, league: @league, name: 'Heim Team'),
                          guest_team: create(:team, league: @league, name: 'Gast Team'))
    @referee = create(:referee, vorname: 'Ada', nachname: 'Adler')
  end

  # ICS faltet Zeilen nach 75 Oktetten (CRLF + Leerzeichen). Ein Kalenderprogramm
  # entfaltet vor dem Lesen — der Test muss das auch tun, sonst reißt jede
  # Prüfung, deren Text zufällig über eine Faltstelle läuft.
  def ics(**overrides)
    raw = RefereeAssignmentCalendar.new(@game.reload, **{ recipient: @referee }.merge(overrides)).to_ical
    raw&.gsub("\r\n ", '')
  end

  test 'Kalenderdatei beschreibt den Termin vollstaendig' do
    body = ics(officials: 'Bo Bauer', coach_name: 'Cem Celik',
               club_contact_email: @club.contact_email, notes: 'Eingang hinten')

    assert_includes body, 'BEGIN:VCALENDAR'
    assert_includes body, 'BEGIN:VEVENT'
    assert_includes body, 'SUMMARY:SR: Heim Team'
    assert_includes body, 'Sporthalle Nord'
    assert_includes body, 'Testliga'
    assert_includes body, '4711'
    assert_includes body, 'Bo Bauer'
    assert_includes body, 'Cem Celik'
    assert_includes body, 'ausrichter@example.de'
    assert_includes body, 'Eingang hinten'
    assert_includes body, @game.url
  end

  # PUBLISH, nicht REQUEST: Eine Einladung würde Zu-/Absagen an das
  # Ansetzungs-Postfach zurückschicken, das niemand auswertet.
  test 'Methode ist PUBLISH' do
    assert_includes ics, 'METHOD:PUBLISH'
    assert_not_includes ics, 'METHOD:REQUEST'
  end

  # Ein Anhang wird oft in einem Kalender geöffnet, der nicht in Europe/Berlin
  # steht. Ohne TZID wäre der Anpfiff eine „floating time" und landete beim
  # Empfänger auf der falschen Uhrzeit.
  test 'Anpfiff traegt die Zeitzone des Spielbetriebs' do
    body = ics

    assert_includes body, 'TZID=Europe/Berlin'
    assert_includes body, 'DTSTART;TZID=Europe/Berlin:20260307T140000'
    assert_includes body, 'BEGIN:VTIMEZONE'
  end

  test 'Termin endet nach der Spieldauer der Liga' do
    body = ics

    minutes = @league.effective_game_duration_minutes
    expected = (Time.zone.parse('2026-03-07 14:00') + minutes.minutes).strftime('%H%M%S')
    assert_includes body, "DTEND;TZID=Europe/Berlin:20260307T#{expected}"
  end

  # Ohne Anpfiffzeit steht der Tag fest, nur die Uhrzeit fehlt. Ein ganztägiger
  # Termin ist nützlicher als gar keiner.
  test 'ohne Anpfiffzeit entsteht ein ganztaegiger Termin' do
    @game.update!(start_time: nil)

    body = ics

    assert_includes body, 'DTSTART;VALUE=DATE:20260307'
    # DTEND ist bei DATE-Werten exklusiv, also der Folgetag.
    assert_includes body, 'DTEND;VALUE=DATE:20260308'
  end

  test 'ohne lesbares Spieltagsdatum entsteht keine Datei' do
    @game_day.update_column(:date, 'unbekannt')

    assert_nil ics
  end

  test 'Coach-Rolle wird im Betreff und bei den Schiris ausgewiesen' do
    body = ics(role: :coach, officials: 'Ada Adler, Bo Bauer')

    assert_includes body, 'SUMMARY:SR-Coach:'
    assert_includes body, 'Schiedsrichter/innen: Ada Adler'
  end

  # Stabile UID: Eine erneut verschickte Datei aktualisiert den vorhandenen
  # Termin statt einen zweiten anzulegen.
  test 'UID haengt an Spiel, Rolle und Person' do
    assert_includes ics, "UID:sm_referee_assignment_#{@game.id}_referee_#{@referee.id}@saisonmanager.org"
    assert_includes ics(role: :coach), "UID:sm_referee_assignment_#{@game.id}_coach_#{@referee.id}@saisonmanager.org"
  end

  test 'Dateiname nennt die Spielnummer' do
    assert_equal 'ansetzung-4711.ics', RefereeAssignmentCalendar.new(@game, recipient: @referee).filename
  end

  test 'leere Angaben tauchen nicht als leere Zeilen auf' do
    body = ics

    assert_not_includes body, 'Schiri-Partner/in:'
    assert_not_includes body, 'Schiedsrichtercoach/in:'
    assert_not_includes body, 'Kontakt Ausrichter:'
  end
end
