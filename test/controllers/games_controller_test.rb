require 'test_helper'

class GamesControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-01')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(
      game_day: @game_day,
      home_team: @home,
      guest_team: @guest,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] },
      special_event_string: 'Interner Vermerk'
    )
  end

  test 'additional_fields liefert dem SBK des Spielbetriebs die internen Felder' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/user/games/#{@game.id}/additional_fields.json"

    assert_response :success
    assert_equal 'Interner Vermerk', JSON.parse(response.body)['special_event_string']
  end

  test 'additional_fields erlaubt dem TM der beteiligten Mannschaft' do
    login(create(:user, :tm, team_id: @home.id))

    get "/api/v2/user/games/#{@game.id}/additional_fields.json"

    assert_response :success
    assert_equal 'Interner Vermerk', JSON.parse(response.body)['special_event_string']
  end

  test 'additional_fields liefert unbeteiligten Logins ein leeres Objekt' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/user/games/#{@game.id}/additional_fields.json"

    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  test 'update_start_end ist für Nicht-Admins gesperrt' do
    login(create(:user, :sbk_global))

    get '/internal/update_games/update_start_end'

    assert_response :forbidden
  end

  test 'update_start_end ist für Admins erlaubt' do
    login(create(:user, :admin))

    get '/internal/update_games/update_start_end'

    assert_response :success
  end

  test 'Anpfiff-Änderung benachrichtigt Schiri und Ausrichter bei veröffentlichter Ansetzung' do
    @club.update!(contact_email: 'ausrichter@example.de')
    referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: referee.id, status: 'published')
    login(create(:user, :admin))

    # Schiri + Ausrichter
    assert_enqueued_emails 2 do
      patch "/api/v2/games/#{@game.id}", params: { game: { start_time: '15:00' } }
    end
    assert_response :success
  end

  test 'Absage (notice_type) benachrichtigt bei veröffentlichter Ansetzung' do
    referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: referee.id, status: 'published')
    login(create(:user, :admin))

    # nur der Schiri (Ausrichter hat keine contact_email)
    assert_enqueued_emails 1 do
      patch "/api/v2/games/#{@game.id}", params: { game: { notice_type: 'Canceled' } }
    end
    assert_response :success
  end

  test 'kein Versand ohne Ansetzung' do
    login(create(:user, :admin))

    assert_no_enqueued_emails do
      patch "/api/v2/games/#{@game.id}", params: { game: { start_time: '15:00' } }
    end
    assert_response :success
  end

  test 'unveränderter Anpfiff/Absage löst keinen Versand aus' do
    referee = create(:referee, email: 'schiri@example.de')
    RefereeAssignment.create!(game: @game, referee1_id: referee.id, status: 'published')
    login(create(:user, :admin))

    # Nur ein anderes (erlaubtes) Feld ändern → keine Benachrichtigung
    assert_no_enqueued_emails do
      patch "/api/v2/games/#{@game.id}", params: { game: { game_number: '99' } }
    end
    assert_response :success
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
