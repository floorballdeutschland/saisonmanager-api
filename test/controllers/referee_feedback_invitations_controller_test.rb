require 'test_helper'

# Abgabe über den Einmal-Link, ohne Anmeldung.
class RefereeFeedbackInvitationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @club = create(:club)
    @home = create(:team, league: @league, club: @club, name: 'Heim')
    @guest = create(:team, league: @league, club: @club, name: 'Gast')
    @game_day = create(:game_day, league: @league, club: @club)
    @game = create(:game,
                   game_day: @game_day,
                   home_team: @home,
                   guest_team: @guest,
                   game_number: '42',
                   game_status: 'match_record_closed',
                   match_record_closed_at: Time.current,
                   players: { 'home' => [], 'guest' => [] })
    @player = create(:player, email: 'kapitaenin@example.com')
    @invitation, @token = RefereeFeedbackInvitation.generate!(
      game: @game, team: @home, email: 'kapitaenin@example.com', player: @player
    )
  end

  test 'unbekannter Token liefert 410 und keine Daten' do
    get '/api/v2/referee_feedback_invitations/gibtesnicht'

    assert_response :gone
    assert_nil JSON.parse(response.body)['team_name']
  end

  test 'gueltiger Token liefert die Kopfdaten des einen Spiels' do
    get "/api/v2/referee_feedback_invitations/#{@token}"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'open', body['status']
    assert_equal 'Heim', body['team_name']
    assert_equal 'Gast', body['opponent_name']
    assert_equal '42', body['game_number']
    assert_equal true, body['home']
  end

  test 'Abgabe legt das Feedback mit Herkunft an und verbraucht den Link' do
    post "/api/v2/referee_feedback_invitations/#{@token}",
         params: { line_rating: 6, communication_rating: 9, general_comment: ' Alles gut ' }

    assert_response :created
    feedback = RefereeFeedback.find_by(game: @game, team: @home)
    assert_equal 6, feedback.line_rating
    assert_equal 'Alles gut', feedback.general_comment
    assert_equal @player.id, feedback.submitted_by_player_id
    assert_equal 'kapitaenin@example.com', feedback.submitted_by_email
    assert_nil feedback.submitted_by_user_id
    assert @invitation.reload.used?
  end

  test 'zweite Abgabe über denselben Link wird abgewiesen' do
    post "/api/v2/referee_feedback_invitations/#{@token}",
         params: { line_rating: 6, communication_rating: 9 }
    assert_response :created

    post "/api/v2/referee_feedback_invitations/#{@token}",
         params: { line_rating: 1, communication_rating: 1 }

    assert_response :unprocessable_entity
    assert_equal 6, RefereeFeedback.find_by(game: @game, team: @home).line_rating
  end

  test 'abgelaufener Link zeigt seinen Zustand und nimmt nichts an' do
    @invitation.update_columns(expires_at: 1.day.ago)

    get "/api/v2/referee_feedback_invitations/#{@token}"
    assert_response :success
    assert_equal 'expired', JSON.parse(response.body)['status']

    post "/api/v2/referee_feedback_invitations/#{@token}",
         params: { line_rating: 6, communication_rating: 9 }

    assert_response :unprocessable_entity
    assert_equal 0, RefereeFeedback.count
  end

  test 'bereits vorhandenes Feedback der Mannschaft blockiert die Abgabe' do
    create(:referee_feedback, game: @game, team: @home, line_rating: 3)

    get "/api/v2/referee_feedback_invitations/#{@token}"
    assert_equal 'submitted', JSON.parse(response.body)['status']

    post "/api/v2/referee_feedback_invitations/#{@token}",
         params: { line_rating: 6, communication_rating: 9 }

    assert_response :unprocessable_entity
    assert_equal 3, RefereeFeedback.find_by(game: @game, team: @home).line_rating
  end

  test 'fehlende Bewertung wird abgewiesen' do
    post "/api/v2/referee_feedback_invitations/#{@token}", params: { line_rating: 6 }

    assert_response :unprocessable_entity
    assert_equal 0, RefereeFeedback.count
  end

  test 'offener Spielbericht laesst noch keine Abgabe zu' do
    @game.update_columns(game_status: 'pregame', match_record_closed_at: nil)

    post "/api/v2/referee_feedback_invitations/#{@token}",
         params: { line_rating: 6, communication_rating: 9 }

    assert_response :unprocessable_entity
    assert_equal 0, RefereeFeedback.count
  end

  test 'deaktivierte Liga nimmt kein Feedback mehr an' do
    @league.update!(referee_feedback_enabled: false)

    get "/api/v2/referee_feedback_invitations/#{@token}"
    assert_equal 'disabled', JSON.parse(response.body)['status']

    post "/api/v2/referee_feedback_invitations/#{@token}",
         params: { line_rating: 6, communication_rating: 9 }

    assert_response :unprocessable_entity
  end
end
