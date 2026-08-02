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

  # Die Sammelliste aller Spiele (Game.all, ohne Filter und ohne Grenze) ist
  # bewusst weg – weder öffentlich noch für Angemeldete.
  test 'die Sammelliste aller Spiele ist nicht mehr erreichbar' do
    assert_raises(ActionController::RoutingError) { get '/api/v2/games.json' }
  end

  test 'die Sammelliste aller Spiele ist auch fuer Angemeldete weg' do
    login(create(:user, :admin))

    assert_raises(ActionController::RoutingError) { get '/api/v2/games.json' }
  end

  test 'ein einzelnes Spiel bleibt abrufbar' do
    login(create(:user, :admin))

    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
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

  # ---------------------------------------------------------------------------
  # Spielbetriebs-Scoping der Schreibpfade (#214)
  # ---------------------------------------------------------------------------

  test 'add_event: SBK des Spielbetriebs darf ein Ereignis eintragen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: { period: 1, time: '10:00' }

    assert_response :success
  end

  test 'add_event: SBK eines fremden Spielbetriebs wird abgewiesen' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: { period: 1, time: '10:00' }

    assert_response :forbidden
    assert_empty @game.reload.events
  end

  test 'set_game_status: SBK eines fremden Spielbetriebs wird abgewiesen' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'ingame' }

    assert_response :forbidden
  end

  # editable steuert im Frontend, ob die Spielbericht-Oberfläche überhaupt
  # erscheint, und erreicht can_edit_lineup? auf einem anderen Weg als die
  # Schreib-Actions (direkt, nicht über can_edit_game?).
  test 'editable: true für den SBK des Spielbetriebs, false für einen fremden' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))
    get "/api/v2/user/games/#{@game.id}/editable"
    assert_response :success
    assert_equal true, response.parsed_body

    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))
    get "/api/v2/user/games/#{@game.id}/editable"
    assert_response :success
    assert_equal false, response.parsed_body
  end

  # Die Sperre bei abgeschlossenem Spielbericht darf nicht über eine
  # fachfremde SBK-Rolle aushebelbar sein (#214, Review-Fund).
  test 'add_event: fremde SBK-Rolle hebelt die Sperre des geschlossenen Berichts nicht aus' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    @game.update!(game_status: 'match_record_closed')
    user = create(:user, :sbk_scoped, game_operation_id: other_go.id)
    user.update!(permissions: user.permissions + [{ 'user_group_id' => 4, 'game_operation_id' => 0,
                                                    'club_id' => @club.id }])
    login(user)

    post "/api/v2/user/games/#{@game.id}/events/add", params: { period: 1, time: '10:00' }

    assert_response :forbidden
    assert_empty @game.reload.events
  end

  # ---------------------------------------------------------------------------
  # Technisches Tor: zugesprochen, also kein Strafschuss, aber mit Vorlage
  # ---------------------------------------------------------------------------

  test 'add_event: technisches Tor behält seine Vorlage und kommt beschriftet zurück' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: {
      period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9,
      goal_type: 'technical'
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_equal '9', event['home_assist'].to_s
    # Schreib- und Leseweg zusammen: nur so fällt auf, wenn die Markierung zwar
    # gespeichert, aber nicht mehr zu einem Label aufgelöst wird.
    assert_equal 'Technisches Tor', response.parsed_body.first['goal_type_string']
  end

  # Der Fall, den sonst nichts abfängt: ein Aufruf mit beiden Markierungen im
  # selben Request (direkter API-Zugriff oder veralteter Client). Das Formular
  # koppelt die Haken, und beim Umstellen eines bestehenden Strafschusses ist
  # der Code ohnehin schon weg, bevor die Bereinigung läuft.
  #
  # Je Schreibweg einmal, weil beide das Ereignis unterschiedlich aufbauen:
  # update_event ändert den string-keyed Hash aus dem JSONB, add_event einen
  # HashWithIndifferentAccess. Gelöscht wird mit String-Key.
  test 'add_event: technisches Tor und Strafschuss zugleich lässt nur die Markierung übrig' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/add", params: {
      period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7,
      goal_type: 'technical', penalty_code_id: 23
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_not event.key?('penalty_code_id')
  end

  test 'update_event: technisches Tor und Strafschuss zugleich lässt nur die Markierung übrig' do
    @game.update!(events: [{ 'id' => 1, 'period' => 1, 'time' => '10:00', 'event_type' => 'goal',
                             'event_team' => 'home', 'home_goals' => 1, 'guest_goals' => 0,
                             'home_number' => 7, 'home_assist' => 9 }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 1, period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9,
      goal_type: 'technical', penalty_code_id: 23
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_not event.key?('penalty_code_id')
    assert_equal '9', event['home_assist'].to_s
  end

  test 'update_event: Umstellen eines Strafschusses auf technisches Tor' do
    @game.update!(events: [{ 'id' => 1, 'period' => 1, 'time' => '10:00', 'event_type' => 'goal',
                             'event_team' => 'home', 'home_goals' => 1, 'guest_goals' => 0,
                             'home_number' => 7, 'home_assist' => 9, 'penalty_code_id' => 23 }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 1, period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9, goal_type: 'technical'
    }

    assert_response :success
    event = @game.reload.events.first
    assert_equal 'technical', event['goal_type']
    assert_nil event['penalty_code_id']
    assert_equal '9', event['home_assist'].to_s
  end

  test 'update_event: Umstellen zurück auf reguläres Tor löscht die Markierung' do
    @game.update!(events: [{ 'id' => 1, 'period' => 1, 'time' => '10:00', 'event_type' => 'goal',
                             'event_team' => 'home', 'home_goals' => 1, 'guest_goals' => 0,
                             'home_number' => 7, 'home_assist' => 9, 'goal_type' => 'technical' }])
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/events/update", params: {
      event_id: 1, period: 1, time: '10:00', event_type: 'goal', event_team: 'home',
      home_goals: 1, guest_goals: 0, home_number: 7, home_assist: 9
    }

    assert_response :success
    event = @game.reload.events.first
    assert_nil event['goal_type']
    assert_equal '9', event['home_assist'].to_s
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
