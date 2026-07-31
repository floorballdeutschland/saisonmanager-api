require 'test_helper'

# Die 24h-Erinnerung an das Berichtsformular hängt am digitalen Berichtsworkflow.
# Maßgeblich ist der LV des Spielbetriebs, nicht der des Ausrichtervereins: ein
# Bundesliga-Spiel in der Halle eines anderen LV folgt dem ausrichtenden
# Spielbetrieb (siehe Game#report_form_state_association).
class GamesIncidentReportReminderTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @go_sa = create(:state_association, report_form_email_enabled: true)
    @club_sa = create(:state_association, report_form_email_enabled: false)
    @go = create(:game_operation, state_association_id: @go_sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @club_sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-01')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(
      game_day: @game_day,
      home_team: @home,
      guest_team: @guest,
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] },
      special_event: true,
      referee1_string: '12345 Eree, Ref'
    )
    r1 = create(:referee, email: 'ref1@example.de')
    r2 = create(:referee, email: 'ref2@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: r1.id, referee2_id: r2.id, status: 'published')
  end

  test 'aktivierter Berichtsworkflow des Spielbetriebs-LV löst die Erinnerung aus' do
    login(create(:user, :admin))

    assert_enqueued_emails 1 do
      close_match_record
    end
    assert_response :success
  end

  test 'deaktivierter Berichtsworkflow des Spielbetriebs-LV löst keine Erinnerung aus' do
    @go_sa.update!(report_form_email_enabled: false)
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      close_match_record
    end
    assert_response :success
  end

  test 'der LV des Ausrichtervereins entscheidet nicht über die Erinnerung' do
    @go_sa.update!(report_form_email_enabled: false)
    @club_sa.update!(report_form_email_enabled: true)
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      close_match_record
    end
    assert_response :success
  end

  test 'ohne besonderes Ereignis und ohne Spielausschluss bleibt es still' do
    @game.update!(special_event: false)
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      close_match_record
    end
    assert_response :success
  end

  test 'ein Spielausschluss löst die Erinnerung auch ohne besonderes Ereignis aus' do
    @game.update!(special_event: false, events: [{ 'id' => 1, 'penalty_id' => '5', 'penalty_code_id' => '7' }])
    login(create(:user, :admin))

    assert_enqueued_emails 1 do
      close_match_record
    end
    assert_response :success
  end

  private

  def close_match_record
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'match_record_closed' }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
