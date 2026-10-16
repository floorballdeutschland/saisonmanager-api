require 'test_helper'

# Tabletmodus: Schüsse, Verknüpfung mit Toren, öffentliche Statistik (api#816).
class GameShotsControllerTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-10-11')
    @game = build_game(@game_day)
    @other_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2, date: '2026-10-18')
    @foreign_game = build_game(@other_day)
    @link, @token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))
    @t0 = Time.zone.parse('2026-10-11 18:10:00.250 +02:00')
  end

  # --- Serverzeit ---------------------------------------------------------------

  test 'server_time ist ganz offen und liefert Millisekunden' do
    get '/api/v2/server_time.json'

    assert_response :success
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, response.parsed_body['now'])
  end

  # --- Anlegen, idempotent ---------------------------------------------------------

  test 'Sekretariats-Link legt Schüsse an, markiert das Spiel und liefert alle Schüsse' do
    post_shots([shot('a', result: 'goal'), shot('b', result: 'saved', at: @t0 + 30)])

    assert_response :success
    body = response.parsed_body['shots']
    assert_equal(%w[a b], body.map { |s| s['client_uuid'] })
    assert_equal '2026-10-11T16:10:00.250Z', body.first['tapped_at'], 'Millisekunden bleiben erhalten'
    assert_in_delta 0.8, body.first['x']
    assert_nil body.first['event_id']
    assert @game.reload.tablet_capture?
  end

  test 'erneutes Schicken derselben client_uuid aktualisiert statt zu verdoppeln' do
    post_shots([shot('a', result: 'saved')])
    post_shots([shot('a', result: 'goal', shooter: 77), shot('b')])

    assert_response :success
    assert_equal 2, @game.game_shots.count
    assert_equal 'goal', GameShot.find_by(client_uuid: 'a').result
    assert_equal 77, GameShot.find_by(client_uuid: 'a').shooter_player_id
  end

  test 'ein ungültiger Schuss weist den ganzen Stapel ab' do
    post_shots([shot('a'), shot('b', pos_x: 1.5)])

    assert_response :unprocessable_entity
    assert_equal 0, GameShot.count
    assert_not @game.reload.tablet_capture?
  end

  test 'eine client_uuid eines anderen Spiels wird nicht übernommen' do
    GameShot.create!(shot('a').merge(game: @foreign_game))

    post_shots([shot('a')])

    assert_response :unprocessable_entity
    assert_equal @foreign_game.id, GameShot.find_by(client_uuid: 'a').game_id
  end

  # --- Rechte ----------------------------------------------------------------------

  test 'ohne Anmeldung und ohne Link: 401' do
    post "/api/v2/games/#{@game.id}/shots.json", params: { shots: [shot('a')] }, as: :json

    assert_response :unauthorized
  end

  test 'der Link deckt nur seine Spieltage ab' do
    post_shots([shot('a')], game: @foreign_game)

    assert_response :forbidden
  end

  test 'nach dem Abschluss schreiben nur Admin und SBK des Spielbetriebs' do
    @game.update!(game_status: 'match_record_closed')
    post_shots([shot('a')])
    assert_response :forbidden

    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))
    post "/api/v2/games/#{@game.id}/shots.json", params: { shots: [shot('a')] }, as: :json
    assert_response :success
  end

  test 'Vereinsmanager der beteiligten Mannschaft darf schreiben und lesen' do
    login_as(create(:user, :vm, club_id: @club.id))
    post "/api/v2/games/#{@game.id}/shots.json", params: { shots: [shot('a')] }, as: :json
    assert_response :success

    get "/api/v2/games/#{@game.id}/shots.json"
    assert_response :success
    assert_equal(['a'], response.parsed_body['shots'].map { |s| s['client_uuid'] })
  end

  test 'fremder Vereinsmanager: 403' do
    login_as(create(:user, :vm, club_id: create(:club).id))
    get "/api/v2/games/#{@game.id}/shots.json"

    assert_response :forbidden
  end

  # --- Ändern, Löschen ------------------------------------------------------------

  test 'PATCH ändert Teilfelder; aus Tor wird gehalten, die Verknüpfung fällt weg' do
    post_shots([shot('a', result: 'goal')])
    GameShot.find_by(client_uuid: 'a').update!(event_id: 1)

    patch "/api/v2/games/#{@game.id}/shots/a.json", params: { result: 'saved', goalkeeper_player_id: 5 },
                                                    headers: token_header, as: :json

    assert_response :success
    geaendert = response.parsed_body['shots'].first
    assert_equal 'saved', geaendert['result']
    assert_equal 5, geaendert['goalkeeper_player_id']
    assert_nil geaendert['event_id']
    assert_in_delta 0.8, geaendert['x'], 0.0001, 'nicht geschickte Felder bleiben'
  end

  test 'DELETE entfernt den Schuss, unbekannte client_uuid ist 404' do
    post_shots([shot('a'), shot('b')])

    delete "/api/v2/games/#{@game.id}/shots/a.json", headers: token_header
    assert_response :success
    assert_equal(['b'], response.parsed_body['shots'].map { |s| s['client_uuid'] })

    delete "/api/v2/games/#{@game.id}/shots/gibtsnicht.json", headers: token_header
    assert_response :not_found
  end

  # --- Verknüpfung ------------------------------------------------------------------

  test 'add_event verknüpft den jüngsten unverknüpften Tor-Schuss desselben Teams' do
    post_shots([shot('alt', result: 'goal', at: @t0), shot('neu', result: 'goal', at: @t0 + 60),
                shot('gast', result: 'goal', team: 'guest', at: @t0 + 90), shot('vorbei', result: 'missed', at: @t0 + 95)])

    add_goal('home', 1, 0)

    assert_response :success
    assert_equal 1, GameShot.find_by(client_uuid: 'neu').event_id
    assert_nil GameShot.find_by(client_uuid: 'alt').event_id
    assert_nil GameShot.find_by(client_uuid: 'gast').event_id

    add_goal('home', 2, 0)
    assert_equal 2, GameShot.find_by(client_uuid: 'alt').event_id
  end

  test 'ohne passenden Schuss bleibt das Tor unverknüpft und wird trotzdem gespeichert' do
    post_shots([shot('gast', result: 'goal', team: 'guest')])

    add_goal('home', 1, 0)

    assert_response :success
    assert_equal 1, @game.reload.events.size
    assert_nil GameShot.find_by(client_uuid: 'gast').event_id
  end

  test 'Löschen des Tores löst die Verknüpfung, der Schuss bleibt' do
    post_shots([shot('a', result: 'goal')])
    add_goal('home', 1, 0)
    GameShot.find_by(client_uuid: 'a').update!(event_id: 1)

    post "/api/v2/user/games/#{@game.id}/events/remove", params: { event_id: 1 }, headers: token_header, as: :json

    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'a').event_id
  end

  test 'manuell verknüpfen, umhängen und lösen' do
    post_shots([shot('a', result: 'goal'), shot('b', result: 'goal', at: @t0 + 5)])
    add_goal('home', 1, 0) # verknüpft b

    post "/api/v2/games/#{@game.id}/shots/a/link.json", params: { event_id: 1 }, headers: token_header, as: :json
    assert_response :success
    assert_equal 1, GameShot.find_by(client_uuid: 'a').event_id
    assert_nil GameShot.find_by(client_uuid: 'b').event_id, 'ein Tor trägt höchstens einen Schuss'

    post "/api/v2/games/#{@game.id}/shots/a/link.json", params: { event_id: nil }, headers: token_header, as: :json
    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'a').event_id
  end

  test 'verknüpfen nur Tor-Schuss mit vorhandenem Tor' do
    post_shots([shot('a', result: 'saved'), shot('b', result: 'goal')])

    post "/api/v2/games/#{@game.id}/shots/a/link.json", params: { event_id: 1 }, headers: token_header, as: :json
    assert_response :unprocessable_entity

    post "/api/v2/games/#{@game.id}/shots/b/link.json", params: { event_id: 99 }, headers: token_header, as: :json
    assert_response :unprocessable_entity
  end

  # --- Vollständigkeit und Spiel-JSON --------------------------------------------

  test 'tablet_capture setzt die Vollständigkeit, die Spiel-JSON zeigt beides' do
    get "/api/v2/games/#{@game.id}.json", headers: { 'X-Api-Key' => API_KEY }
    assert_equal false, response.parsed_body['tablet_capture']
    assert_nil response.parsed_body['tablet_shots_complete']

    post_shots([shot('a')])
    put "/api/v2/games/#{@game.id}/tablet_capture.json", params: { complete: false }, headers: token_header, as: :json

    assert_response :success
    assert_equal({ 'tablet_shots_complete' => false }, response.parsed_body)
    get "/api/v2/games/#{@game.id}.json", headers: { 'X-Api-Key' => API_KEY }
    assert_equal true, response.parsed_body['tablet_capture']
    assert_equal false, response.parsed_body['tablet_shots_complete']
  end

  # --- Öffentliche Statistik --------------------------------------------------------

  test 'detailed_stats: 404 ohne Tabletmodus, API-Schlüssel nötig' do
    get "/api/v2/games/#{@game.id}/detailed_stats.json"
    assert_response :unauthorized

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }
    assert_response :not_found
  end

  test 'detailed_stats rechnet Summen, Torhüter und Spieler mit öffentlichen Namen' do
    versteckt = create(:player, first_name: 'Max', last_name: 'Geheim', public_last_name_hidden_at: Time.current)
    @game.update!(ended: true, players: {
                    'home' => [{ 'player_id' => versteckt.id, 'trikot_number' => 7,
                                 'player_firstname' => 'Max', 'player_name' => 'Geheim' }],
                    'guest' => [{ 'player_id' => 501, 'trikot_number' => 1,
                                  'player_firstname' => 'Tim', 'player_name' => 'Hüter' }]
                  })
    PublicPlayerNames.flush!
    post_shots([
      shot('1', result: 'goal', shooter: versteckt.id, goalie: 501),
      shot('2', result: 'saved', shooter: versteckt.id, goalie: 501, at: @t0 + 10),
      shot('3', result: 'saved', goalie: 501, at: @t0 + 20, period: 2),
      shot('4', result: 'blocked', at: @t0 + 30, period: 2),
      shot('5', result: 'missed', team: 'guest', at: @t0 + 40)
    ])

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    stats = response.parsed_body
    assert_nil stats['complete']
    assert_equal 5, stats['shots'].size
    assert_equal({ 'trikot_number' => 7, 'name' => 'Max' }, stats['shots'].first['shooter'])
    assert stats['shots'].all? { |s| s.key?('event_id') }
    assert_not_includes response.body, 'Geheim'

    heim = stats['teams']['home']
    assert_equal({ 'shots' => 4, 'on_goal' => 3, 'goals' => 1, 'blocked' => 1, 'missed' => 0 }, heim.except('by_period'))
    assert_equal 2, heim['by_period']['2']['shots']
    assert_equal 0, stats['teams']['guest']['by_period']['2']['shots'], 'gleiche Abschnitte für beide Teams'

    assert_equal [{ 'team' => 'guest', 'trikot_number' => 1, 'name' => 'Tim Hüter', 'saves' => 2,
                    'shots_against' => 3, 'save_pct' => 0.667 }], stats['goalkeepers']
    assert_equal [{ 'team' => 'home', 'trikot_number' => 7, 'name' => 'Max', 'shots' => 2, 'on_goal' => 2,
                    'goals' => 1 }], stats['players']
  end

  test 'detailed_stats: ein neuer Schuss leert den Zwischenspeicher' do
    with_real_cache do
      @game.update!(ended: true)
      post_shots([shot('a')])
      get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }
      assert_equal 1, response.parsed_body['shots'].size

      post_shots([shot('b', at: @t0 + 5)])
      get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }
      assert_equal 2, response.parsed_body['shots'].size
    end
  end

  test 'detailed_stats: verzögerter API-Schlüssel sieht frische Schüsse laufender Spiele nicht' do
    post_shots([shot('alt', at: 30.minutes.ago), shot('frisch', at: 1.minute.ago)])

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal 1, response.parsed_body['shots'].size
  end

  private

  def build_game(game_day)
    Game.create!(game_day: game_day,
                 home_team: create(:team, league: @league, club: @club),
                 guest_team: create(:team, league: @league, club: create(:club)),
                 forfait: 0, overtime: false, legacy: false, events: [],
                 players: { 'home' => [], 'guest' => [] })
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def token_header
    { 'X-Secretary-Token' => @token }
  end

  def post_shots(shots, game: @game)
    post "/api/v2/games/#{game.id}/shots.json", params: { shots: shots }, headers: token_header, as: :json
  end

  def shot(uuid, result: 'saved', team: 'home', at: @t0, pos_x: 0.8, period: 1, shooter: nil, goalie: nil)
    { client_uuid: uuid, team: team, period: period, game_time: '12:34', tapped_at: at.utc.iso8601(3),
      x: pos_x, y: 0.4, result: result, shooter_player_id: shooter, goalkeeper_player_id: goalie }
  end

  def add_goal(team, home, guest)
    post "/api/v2/user/games/#{@game.id}/events/add",
         params: { event_type: 'goal', event_team: team, period: 1, time: '15:00', home_goals: home,
                   guest_goals: guest, "#{team}_number": 2000 },
         headers: token_header, as: :json
  end
end
