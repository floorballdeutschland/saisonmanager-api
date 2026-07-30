require 'test_helper'

# Die zusätzlichen Spielinformationen des Ansetzers sollen mit der Ansetzung
# beim Gespann ankommen: in der Veröffentlichungs-Mail an die Schiris, in der an
# den Coach und in der Änderungs-Mail. Testtexte bewusst ohne Umlaute, damit die
# quoted-printable-Kodierung des Bodys die Suche nicht zerlegt.
class RefereeAssignmentNotesMailTest < ActionMailer::TestCase
  NOTE = 'Halleneingang an der Rueckseite'.freeze

  setup do
    create(:setting)
    @club = create(:club, contact_email: 'ausrichter@example.de')
    @league = create(:league, game_operation: create(:game_operation, :national))
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date: '2026-03-01')
    @game = Game.create!(game_day: @game_day,
                         home_team: create(:team, league: @league, club: @club),
                         guest_team: create(:team, league: @league, club: @club),
                         start_time: '14:30', forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })
    @referee = create(:referee, email: 'schiri@example.de')
    @partner = create(:referee, email: 'partner@example.de')
    @coach = create(:referee, email: 'coach@example.de')
    RefereeAssignment.create!(game: @game, referee1: @referee, referee2: @partner, coach: @coach,
                              status: 'published', published_at: Time.current)
    @game.reload
  end

  test 'Ansetzungs-Mail an den Schiri enthaelt die Spielinformationen' do
    @game.update!(referee_notes: NOTE)

    body = RefereeMailer.published_assignment_notification(
      @referee, @game.reload, @partner, @club.contact_email, coach: @coach
    ).body.encoded

    assert_includes body, 'Spielinformationen'
    assert_includes body, NOTE
  end

  test 'Ansetzungs-Mail an den Coach enthaelt die Spielinformationen' do
    @game.update!(referee_notes: NOTE)

    body = RefereeMailer.published_coach_notification(
      @coach, @game.reload, 'Vor Nach', @club.contact_email
    ).body.encoded

    assert_includes body, NOTE
  end

  test 'Aenderungs-Mail enthaelt die Spielinformationen' do
    @game.update!(referee_notes: NOTE)

    body = RefereeMailer.updated_assignment_notification(@referee, @game.reload, 'Vor Nach', @coach).body.encoded

    assert_includes body, NOTE
  end

  test 'ohne hinterlegte Spielinformationen bleibt der Abschnitt weg' do
    body = RefereeMailer.published_assignment_notification(
      @referee, @game, @partner, @club.contact_email
    ).body.encoded

    assert_not_includes body, 'Spielinformationen'
  end

  test 'Zeilenumbrueche der Notiz bleiben im Mailtext erhalten' do
    @game.update!(referee_notes: "Erste Zeile\nZweite Zeile")

    body = RefereeMailer.published_assignment_notification(
      @referee, @game.reload, @partner, @club.contact_email
    ).body.encoded

    assert_includes body, 'Erste Zeile'
    assert_includes body, 'Zweite Zeile'
    assert_includes body, '<br'
  end

  test 'gepflegte Vorlage kann die Spielinformationen als Platzhalter nutzen' do
    @game.update!(referee_notes: NOTE)
    EmailTemplate.create!(
      mailer_class: 'RefereeMailer', action_name: 'published_assignment_notification', locale: 'de',
      body: '<p>Infos: {{referee_notes}}</p>'
    )

    body = RefereeMailer.published_assignment_notification(
      @referee, @game.reload, @partner, @club.contact_email
    ).body.encoded

    assert_includes body, NOTE
  end

  test 'HTML in der Notiz wird nicht als Markup ausgeliefert' do
    @game.update!(referee_notes: '<script>alert(1)</script> Hinweis')

    body = RefereeMailer.published_assignment_notification(
      @referee, @game.reload, @partner, @club.contact_email
    ).body.encoded

    assert_not_includes body, '<script>'
    assert_includes body, 'Hinweis'
  end

  test 'aus der Ansetzung genommener Schiri bekommt die Spielinformationen nicht' do
    @game.update!(referee_notes: NOTE)
    removed = create(:referee, email: 'raus@example.de')

    body = RefereeMailer.updated_assignment_notification(removed, @game.reload, 'Vor Nach', @coach).body.encoded

    assert_not_includes body, NOTE
    assert_not_includes body, 'Spielinformationen'
  end

  test 'vor dem Veroeffentlichen enthaelt keine Mail die Spielinformationen' do
    @game.update!(referee_notes: NOTE)
    @game.referee_assignment.update!(status: 'tentative')

    body = RefereeMailer.published_assignment_notification(
      @referee, @game.reload, @partner, @club.contact_email
    ).body.encoded

    assert_not_includes body, NOTE
  end
end
