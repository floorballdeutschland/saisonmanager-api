require 'test_helper'

# Der Rohtoken existiert absichtlich nur in dieser Mail (gespeichert wird nur sein
# Digest). Ein Fehler in Betreff, Empfänger oder Link macht das Feature also
# lautlos unbenutzbar, deshalb wird die Mail hier wirklich gerendert.
class RefereeFeedbackMailerTest < ActionMailer::TestCase
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true, name: 'Testliga')
    @club = create(:club)
    @home = create(:team, league: @league, club: @club, name: 'Heim')
    @guest = create(:team, league: @league, club: @club, name: 'Gast')
    @game_day = create(:game_day, league: @league, club: @club)
    @game = create(:game,
                   game_day: @game_day,
                   home_team: @home,
                   guest_team: @guest,
                   game_status: 'match_record_closed',
                   match_record_closed_at: Time.current,
                   players: { 'home' => [], 'guest' => [] })
  end

  test 'Einladung enthaelt Empfaenger, Rohtoken und Abgabe-Adresse' do
    invitation, raw_token = RefereeFeedbackInvitation.generate!(
      game: @game, team: @home, email: 'kapitaen@example.com'
    )

    mail = RefereeFeedbackMailer.invitation(invitation, raw_token)

    assert_equal ['kapitaen@example.com'], mail.to
    assert_equal 'Schiri-Feedback abgeben – Heim', mail.subject

    body = mail.body.encoded
    assert_includes body, raw_token
    assert_includes body, "/schiri-feedback/abgeben/#{raw_token}"
    assert_includes body, 'Heim'
    assert_includes body, 'Gast'
    assert_includes body, 'innerhalb von 24 Stunden'
    assert_not_includes body, invitation.token_digest
  end

  test 'Einladung an die Kapitaenin begruendet die Zustellung anders als an den Team-Kontakt' do
    invitation, raw_token = RefereeFeedbackInvitation.generate!(
      game: @game, team: @home, email: 'kapitaenin@example.com'
    )

    captain_body = RefereeFeedbackMailer.invitation(invitation, raw_token, source: :captain).body.encoded
    assert_includes captain_body, 'Kapitän*in'

    contact_body = RefereeFeedbackMailer.invitation(invitation, raw_token, source: :team_contact).body.encoded
    assert_includes contact_body, 'als Kontakt für das Schiedsrichter-Feedback hinterlegt'
  end

  test 'Teammanager-Info verweist auf die Feedback-Seite' do
    tm = create(:user, :tm, team_id: @home.id, email: 'tm@example.com')

    mail = RefereeFeedbackMailer.form_available(tm, @game, @home)

    assert_equal ['tm@example.com'], mail.to
    assert_includes mail.body.encoded, '/verein/schiri-feedback'
    assert_includes mail.body.encoded, 'Heim'
  end
end
