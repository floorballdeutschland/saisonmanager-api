require 'test_helper'

# Versand beim Abschluss des Spielberichts: Einladung an den Feedback-Kontakt
# (falls einer hinterlegt ist) plus in jedem Fall die Info an die Teammanager.
class RefereeFeedbackNotifierTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @club = create(:club)
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game_day = create(:game_day, league: @league, club: @club)
    @game = create(:game,
                   game_day: @game_day,
                   home_team: @home,
                   guest_team: @guest,
                   game_status: 'match_record_closed',
                   match_record_closed_at: Time.current,
                   players: { 'home' => [], 'guest' => [] })
    @tm = create(:user, :tm, team_id: @home.id, email: 'tm@example.com')
  end

  test 'ohne Feedback-Kontakt gibt es nur die Teammanager-Info und keine Einladung' do
    assert_equal 1, RefereeFeedbackNotifier.new(@game).notify
    assert_equal 0, RefereeFeedbackInvitation.count
  end

  test 'mit eingetragener Adresse entsteht eine Einladung zusaetzlich zur Teammanager-Info' do
    @home.update!(feedback_contact_email: 'kapitaen@example.com')

    assert_equal 2, RefereeFeedbackNotifier.new(@game).notify

    invitation = RefereeFeedbackInvitation.find_by(game: @game, team: @home)
    assert_equal 'kapitaen@example.com', invitation.email
    assert_nil invitation.player_id
    assert_in_delta 14.days.from_now, invitation.expires_at, 5.seconds
    assert_nil invitation.used_at
  end

  test 'ein fehlgeschlagener Versand reisst die uebrigen Mails nicht mit' do
    @home.update!(feedback_contact_email: 'kapitaen@example.com')

    failing = Object.new
    def failing.deliver_now
      raise Net::SMTPFatalError, 'Empfänger abgelehnt'
    end

    def failing.deliver_later
      raise Net::SMTPFatalError, 'Empfänger abgelehnt'
    end

    mails = RefereeFeedbackMailer.stub(:invitation, ->(*, **) { failing }) do
      RefereeFeedbackNotifier.new(@game).notify
    end

    # Nur die Teammanager-Info zählt, der Abschluss bleibt aber vermerkt, damit
    # die erfolgreiche Mail beim nächsten Lauf nicht erneut rausgeht.
    assert_equal 1, mails
    assert_not_nil @game.reload.referee_feedback_notified_at
  end

  test 'Kapitaenin des Spiels wird mit Spielerprofil verknuepft' do
    captain = create(:player, email: 'kapitaenin@example.com')
    @game.update!(players: {
                    'home' => [{ 'trikot_number' => 7, 'player_id' => captain.id, 'captain' => true }],
                    'guest' => []
                  })
    @home.update!(feedback_contact_prefer_captain: true)

    RefereeFeedbackNotifier.new(@game).notify

    invitation = RefereeFeedbackInvitation.find_by(game: @game, team: @home)
    assert_equal 'kapitaenin@example.com', invitation.email
    assert_equal captain.id, invitation.player_id
  end

  test 'bereits abgegebenes Feedback erzeugt keine Einladung mehr' do
    @home.update!(feedback_contact_email: 'kapitaen@example.com')
    create(:referee_feedback, game: @game, team: @home)

    RefereeFeedbackNotifier.new(@game).notify

    assert_equal 0, RefereeFeedbackInvitation.where(team: @home).count
  end

  test 'Versand bleibt idempotent ueber referee_feedback_notified_at' do
    @home.update!(feedback_contact_email: 'kapitaen@example.com')

    RefereeFeedbackNotifier.new(@game).notify
    assert_equal 0, RefereeFeedbackNotifier.new(@game.reload).notify
    assert_equal 1, RefereeFeedbackInvitation.count
  end
end
