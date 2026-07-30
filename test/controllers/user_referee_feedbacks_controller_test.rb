require 'test_helper'

# Der angemeldete Abgabeweg (TM/VM). Vorher ungetestet, mit dem Umbau auf
# RefereeFeedbackSubmission aber genau der Pfad, der nicht regressieren darf:
# 201 bei der ersten Abgabe, 200 bei der Wiederholung, und die Herkunft muss am
# Benutzerkonto hängen und nicht an Spieler/Adresse.
class UserRefereeFeedbacksControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @league = create(:league, referee_feedback_enabled: true)
    @club = create(:club)
    @home = create(:team, league: @league, club: @club, name: 'Heim')
    @guest = create(:team, league: @league, club: @club, name: 'Gast')
    # Zwei Tage zurück, damit die 24-Stunden-Sperre (RefereeFeedbackWindow) offen
    # ist und die Tests unten die Abgabe selbst prüfen.
    @game_day = create(:game_day, league: @league, club: @club, date: 2.days.ago.to_date.to_s)
    @game = create(:game,
                   game_day: @game_day,
                   home_team: @home,
                   guest_team: @guest,
                   game_status: 'match_record_closed',
                   match_record_closed_at: 1.hour.ago,
                   players: { 'home' => [], 'guest' => [] })
    @tm = create(:user, :tm, team_id: @home.id, email: 'tm@example.com')
  end

  test 'erste Abgabe legt das Feedback mit dem Benutzerkonto als Herkunft an' do
    login(@tm)

    post '/api/v2/user/referee_feedbacks',
         params: { game_id: @game.id, team_id: @home.id, line_rating: 7, communication_rating: 8 }

    assert_response :created
    feedback = RefereeFeedback.find_by(game: @game, team: @home)
    assert_equal @tm.id, feedback.submitted_by_user_id
    assert_nil feedback.submitted_by_player_id
    assert_nil feedback.submitted_by_email
  end

  test 'zweite Abgabe aendert nichts und meldet den Status' do
    login(@tm)
    post '/api/v2/user/referee_feedbacks',
         params: { game_id: @game.id, team_id: @home.id, line_rating: 7, communication_rating: 8 }
    assert_response :created

    post '/api/v2/user/referee_feedbacks',
         params: { game_id: @game.id, team_id: @home.id, line_rating: 1, communication_rating: 1 }

    assert_response :ok
    assert_equal true, JSON.parse(response.body)['done']
    assert_equal 7, RefereeFeedback.find_by(game: @game, team: @home).line_rating
    assert_equal 1, RefereeFeedback.count
  end

  test 'fremde Mannschaft wird abgewiesen' do
    foreign_tm = create(:user, :tm, team_id: @guest.id, email: 'gast-tm@example.com')
    login(foreign_tm)

    post '/api/v2/user/referee_feedbacks',
         params: { game_id: @game.id, team_id: @home.id, line_rating: 7, communication_rating: 8 }

    assert_response :forbidden
    assert_equal 0, RefereeFeedback.count
  end

  test 'unsinnige Bewertung wird auf Deutsch abgewiesen' do
    login(@tm)

    post '/api/v2/user/referee_feedbacks',
         params: { game_id: @game.id, team_id: @home.id, line_rating: 42, communication_rating: 8 }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)['error'], 'Bewertungen'
    assert_equal 0, RefereeFeedback.count
  end

  test 'Abgabe vor Ablauf der 24 Stunden nach dem Spiel wird abgewiesen' do
    @game_day.update!(date: Date.current.to_s)
    login(@tm)

    post '/api/v2/user/referee_feedbacks',
         params: { game_id: @game.id, team_id: @home.id, line_rating: 7, communication_rating: 8 }

    assert_response :unprocessable_entity
    assert_equal RefereeFeedbackSubmission::TOO_EARLY_ERROR, JSON.parse(response.body)['error']
    assert_equal 0, RefereeFeedback.count
  end

  test 'Uebersicht listet das Spiel schon vor Ablauf der 24 Stunden mit kuenftigem fillable_from' do
    @game_day.update!(date: Date.current.to_s)
    login(@tm)

    get '/api/v2/user/referee_feedbacks'

    assert_response :success
    entry = JSON.parse(response.body).first
    assert_not_nil entry
    assert_operator Time.zone.parse(entry['fillable_from']), :>, Time.current
  end

  test 'Uebersicht nennt nur die Einladung der eigenen Mannschaft' do
    RefereeFeedbackInvitation.generate!(game: @game, team: @home, email: 'kapitaen-heim@example.com')
    RefereeFeedbackInvitation.generate!(game: @game, team: @guest, email: 'kapitaen-gast@example.com')

    login(@tm)
    get '/api/v2/user/referee_feedbacks'

    assert_response :success
    entries = JSON.parse(response.body)
    assert_equal 1, entries.size
    assert_equal 'kapitaen-heim@example.com', entries.first['invited_email']
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
