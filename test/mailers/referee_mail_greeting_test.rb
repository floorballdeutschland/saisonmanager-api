require 'test_helper'

# Alle Mails an Schiedsrichter grüßen mit dem Vornamen ("Hallo Anna,"), nicht
# mehr mit dem vollen Namen. Der Vorname steht zusätzlich als Platzhalter
# {{first_name}} bereit, damit auch eine gepflegte Vorlage die Anrede kann.
# Testnamen bewusst ohne Umlaute, damit die quoted-printable-Kodierung des
# Bodys die Suche nicht zerlegt.
class RefereeMailGreetingTest < ActionMailer::TestCase
  setup do
    create(:setting)
    @club = create(:club, contact_email: 'ausrichter@example.de')
    @league = create(:league, game_operation: create(:game_operation, :national))
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date: '2026-03-01')
    @game = Game.create!(game_day: @game_day,
                         home_team: create(:team, league: @league, club: @club),
                         guest_team: create(:team, league: @league, club: @club),
                         start_time: '14:30', game_number: '4711', forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })
    @referee = create(:referee, vorname: 'Anna', nachname: 'Beispiel', email: 'schiri@example.de')
    @partner = create(:referee, vorname: 'Bernd', nachname: 'Muster', email: 'partner@example.de')
    @coach = create(:referee, vorname: 'Clara', nachname: 'Probe', email: 'coach@example.de')
    RefereeAssignment.create!(game: @game, referee1: @referee, referee2: @partner, coach: @coach,
                              status: 'published', published_at: Time.current)
    @game.reload
  end

  test 'Ansetzungs-Mail gruesst nur mit dem Vornamen' do
    body = RefereeMailer.published_assignment_notification(
      @referee, @game, @partner, @club.contact_email, coach: @coach
    ).body.encoded

    assert_includes body, 'Hallo Anna,'
    assert_not_includes body, 'Hallo Anna Beispiel,'
  end

  test 'Aenderungs-Mail gruesst nur mit dem Vornamen' do
    body = RefereeMailer.updated_assignment_notification(@referee, @game, 'Anna Beispiel', @coach).body.encoded

    assert_includes body, 'Hallo Anna,'
    assert_not_includes body, 'Hallo Anna Beispiel,'
  end

  test 'Coach-Mail gruesst nur mit dem Vornamen' do
    body = RefereeMailer.published_coach_notification(
      @coach, @game, 'Anna Beispiel', @club.contact_email
    ).body.encoded

    assert_includes body, 'Hallo Clara,'
    assert_not_includes body, 'Hallo Clara Probe,'
  end

  test 'vorlaeufige Ansetzung gruesst nur mit dem Vornamen' do
    body = RefereeMailer.tentative_assignment_notification(@referee, Date.new(2026, 3, 1)).body.encoded

    assert_includes body, 'Hallo Anna,'
    assert_not_includes body, 'Hallo Anna Beispiel,'
  end

  test 'Lizenz-Mail gruesst nur mit dem Vornamen' do
    body = RefereeMailer.license_notification(@referee).body.encoded

    assert_includes body, 'Hallo Anna,'
    assert_not_includes body, 'Hallo Anna Beispiel,'
  end

  test 'Berichtsformular-Erinnerung gruesst beide Schiris mit Vornamen' do
    body = RefereeMailer.incident_report_reminder(@referee, @partner, @game, 1.day.from_now).body.encoded

    assert_includes body, 'Hallo Anna und Bernd,'
  end

  test 'Entscheidung zum Vereins-Ausschluss gruesst nur mit dem Vornamen' do
    request = RefereeClubExclusionRequest.create!(referee: @referee, club: @club, kind: 'add', status: 'approved',
                                                  reason: 'Eigener Verein')

    body = RefereeMailer.club_exclusion_decision(request).body.encoded

    assert_includes body, 'Hallo Anna,'
    assert_not_includes body, 'Hallo Anna Beispiel,'
  end

  test 'gepflegte Vorlage kann den Vornamen als Platzhalter nutzen' do
    EmailTemplate.create!(
      mailer_class: 'RefereeMailer', action_name: 'published_assignment_notification', locale: 'de',
      body: '<p>Hallo {{first_name}},</p>'
    )

    body = RefereeMailer.published_assignment_notification(
      @referee, @game, @partner, @club.contact_email
    ).body.encoded

    assert_includes body, 'Hallo Anna,'
  end

  test 'Schiedsrichterkonto-Mail gruesst mit dem Vornamen des Kontos' do
    user = create(:user, first_name: 'Dora', last_name: 'Test', email: 'konto@example.de')
    user.update!(password_reset_token: 'tok123')

    body = UserMailer.referee_account_created(user).body.encoded

    assert_includes body, 'Hallo Dora,'
  end

  test 'Schiedsrichterkonto-Mail ohne Vornamen bleibt beim schlichten Hallo' do
    user = create(:user, first_name: nil, last_name: nil, email: 'konto2@example.de')
    user.update!(password_reset_token: 'tok456')

    body = UserMailer.referee_account_created(user).body.encoded

    assert_includes body, 'Hallo,'
  end
end
