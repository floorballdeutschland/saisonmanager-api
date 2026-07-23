require 'test_helper'

class GameDaysControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, contact_email: 'ausrichter@example.de')
    @arena = create(:arena)
    @arena2 = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-04-01')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                         start_time: '14:00', forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })
    @referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: @referee.id, status: 'published')
  end

  test 'Datumsänderung benachrichtigt die Beteiligten der veröffentlichten Ansetzung' do
    login(create(:user, :admin))

    # Schiri + Ausrichter
    assert_enqueued_emails 2 do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { date: '2026-04-08' } }
    end
    assert_response :success
  end

  test 'Hallenwechsel benachrichtigt die Beteiligten' do
    login(create(:user, :admin))

    assert_enqueued_emails 2 do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { arena_id: @arena2.id } }
    end
    assert_response :success
  end

  test 'unveränderte Felder (Datum/Halle) lösen keinen Versand aus' do
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { number: 2 } }
    end
    assert_response :success
  end

  test 'kein Versand ohne veröffentlichte Ansetzung' do
    @game.reload.referee_assignment.update!(status: 'tentative')
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      patch "/api/v2/game_days/#{@game_day.id}", params: { game_day: { date: '2026-04-08' } }
    end
    assert_response :success
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
