require 'test_helper'

# Die Ansetzungsmail trägt den Termin als Kalenderdatei bei. Die Lizenzlisten
# dagegen reisen nicht mehr mit: Ihr Link gilt nur bis zum Tag nach dem Spiel,
# angesetzt wird aber oft Wochen vorher. Sie kommen im Wochenlauf
# (RefereeLicenseListNotifier) kurz vor dem Spiel.
class RefereeAssignmentIcsTest < ActionMailer::TestCase
  setup do
    # Vor dem Spieltag: Der Lizenzlisten-Link gilt nur bis zum Tag nach dem Spiel,
    # ein fixes Datum in der Vergangenheit ergäbe sonst gar keinen Link.
    travel_to Time.utc(2026, 3, 5, 10, 0)
    create(:setting)
    @club = create(:club, contact_email: 'ausrichter@example.de')
    @league = create(:league, game_operation: create(:game_operation, :national))
    @game_day = create(:game_day, league: @league, arena: create(:arena, name: 'Halle Nord'),
                                  club: @club, date: '2026-03-07')
    @game = create(:game, game_day: @game_day, start_time: '14:00', game_number: '4711',
                          home_team: create(:team, league: @league), guest_team: create(:team, league: @league))
    @referee = create(:referee, email: 'schiri@example.de')
    @partner = create(:referee, email: 'partner@example.de')
    @coach = create(:referee, email: 'coach@example.de')
  end

  # `mail.body.encoded` liefert bei einer Mail mit Anhang den kodierten
  # Multipart-Rumpf; quoted-printable bricht dort mitten in Wörtern um. Für
  # Textprüfungen deshalb den dekodierten HTML-Teil lesen.
  def html_of(mail)
    mail.html_part.body.decoded
  end

  def publish_mail
    RefereeMailer.published_assignment_notification(
      @referee, @game.reload, @partner, @club.contact_email, coach: @coach
    )
  end

  test 'Ansetzungsmail an den Schiri traegt den Termin als ICS bei' do
    attachment = publish_mail.attachments.first

    assert_equal 'ansetzung-4711.ics', attachment.filename
    assert_equal 'text/calendar', attachment.mime_type
    assert_includes attachment.body.decoded, 'BEGIN:VEVENT'
    assert_includes attachment.body.decoded, 'Halle Nord'
  end

  # Outlook entscheidet am Content-Type-Parameter, ob es den Anhang als
  # übernehmbaren Termin anbietet – `method=PUBLISH` muss dort stehen.
  test 'Content-Type des Anhangs nennt die Methode' do
    assert_includes publish_mail.attachments.first.content_type, 'method=PUBLISH'
  end

  test 'Ansetzungsmail an den Coach traegt den Termin ebenfalls bei' do
    mail = RefereeMailer.published_coach_notification(
      @coach, @game.reload, 'Ada Adler, Bo Bauer', @club.contact_email
    )

    assert_equal 1, mail.attachments.size
    assert_includes mail.attachments.first.body.decoded, 'SUMMARY:SR-Coach:'
  end

  test 'die Mail erwaehnt den Anhang' do
    assert_includes html_of(publish_mail), 'Kalenderdatei'
  end

  # Ohne lesbares Spieltagsdatum gibt es keinen Termin – die Mail geht dann ohne
  # Anhang raus statt gar nicht, und erwähnt ihn auch nicht.
  test 'ohne lesbares Spieltagsdatum bleibt der Anhang weg' do
    @game_day.update_column(:date, 'unbekannt')

    mail = publish_mail

    assert_empty mail.attachments
    assert_not_includes mail.body.decoded, 'Kalenderdatei'
  end

  test 'ohne Lizenzlisten-Link nennt die Mail den spaeteren Versand' do
    body = html_of(publish_mail)

    assert_not_includes body, 'Lizenzlisten ansehen'
    assert_includes body, 'wenige Tage vor dem Spiel'
  end

  # Kurzfristige Ansetzung: Der Controller gibt den Link mit, weil kein
  # Wochenlauf mehr davorliegt. Dann steht die spielbezogene Gültigkeit dran und
  # nicht mehr „72 Stunden".
  test 'mit Lizenzlisten-Link steht die Gueltigkeit bis zum Tag nach dem Spiel' do
    link = LicenseListLink.new(@game)

    body = html_of(RefereeMailer.published_assignment_notification(
                     @referee, @game.reload, @partner, @club.contact_email,
                     license_list_url: link.url, license_expires_at: link.expires_at
                   ))

    assert_includes body, 'Lizenzlisten ansehen'
    assert_includes body, 'bis zum Tag nach dem Spiel'
    assert_not_includes body, '72 Stunden'
  end
end
