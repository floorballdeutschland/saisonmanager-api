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
    aufstellung!
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
    aufstellung!
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

  test 'add_event verknüpft im selben Team und Abschnitt den Schuss mit der nächsten Spielzeit' do
    post_shots([shot('frueh', result: 'goal', game_time: '03:10', at: @t0),
                shot('nah', result: 'goal', game_time: '14:40', at: @t0 + 60),
                shot('anderer_abschnitt', result: 'goal', game_time: '15:00', period: 2, at: @t0 + 70),
                shot('gast', result: 'goal', team: 'guest', game_time: '15:00', at: @t0 + 90),
                shot('vorbei', result: 'missed', game_time: '15:00', at: @t0 + 95)])

    add_goal('home', 1, 0, time: '15:00')

    assert_response :success
    assert_equal 1, GameShot.find_by(client_uuid: 'nah').event_id
    %w[frueh anderer_abschnitt gast vorbei].each { |uuid| assert_nil GameShot.find_by(client_uuid: uuid).event_id }
  end

  test 'mehrere nachgetragene Tore werden nach Spielzeit gepaart, nicht nach Reihenfolge' do
    post_shots([shot('s1', result: 'goal', game_time: '05:00', at: @t0),
                shot('s2', result: 'goal', game_time: '11:00', at: @t0 + 360),
                shot('s3', result: 'goal', game_time: '18:00', at: @t0 + 780)])

    # Vom Papier, in umgekehrter Reihenfolge eingetragen. Jedes Tor schiebt sich
    # vor ein erfasstes und braucht deshalb die Bestätigung (#835).
    add_goal('home', 3, 0, time: '18:05')
    add_goal('home', 1, 0, time: '05:10', confirm: true)
    add_goal('home', 2, 0, time: '11:20', confirm: true)

    assert_equal({ 's1' => 2, 's2' => 3, 's3' => 1 },
                 GameShot.where(game: @game).order(:client_uuid).to_h { |shot| [shot.client_uuid, shot.event_id] })
  end

  test 'ohne Spielzeit gewinnt der älteste unverknüpfte Schuss' do
    post_shots([shot('alt', result: 'goal', game_time: nil, at: @t0),
                shot('neu', result: 'goal', game_time: nil, at: @t0 + 60)])

    add_goal('home', 1, 0)

    assert_equal 1, GameShot.find_by(client_uuid: 'alt').event_id
  end

  test 'nachgereichte Tor-Schüsse finden das schon eingetragene Tor' do
    add_goal('home', 1, 0, time: '04:00')
    add_goal('home', 2, 0, time: '09:00')
    add_goal('guest', 2, 1, time: '09:30')

    post_shots([shot('spaet2', result: 'goal', game_time: '08:50', at: @t0 + 300),
                shot('spaet1', result: 'goal', game_time: '03:55', at: @t0)])

    assert_response :success
    shots = response.parsed_body['shots'].to_h { |s| [s['client_uuid'], s['event_id']] }
    assert_equal({ 'spaet1' => 1, 'spaet2' => 2 }, shots)
  end

  test 'Umwandlung des Tores in eine Strafe und Teamwechsel lösen die Verknüpfung' do
    post_shots([shot('a', result: 'goal'), shot('b', result: 'goal', at: @t0 + 1)])
    add_goal('home', 1, 0)
    add_goal('home', 2, 0)
    assert_equal [1, 2], GameShot.where(game: @game).order(:client_uuid).pluck(:event_id)

    post "/api/v2/user/games/#{@game.id}/events/update",
         params: { event_id: 1, event_type: 'penalty', event_team: 'home', period: 1, time: '15:00',
                   home_goals: 0, guest_goals: 0, home_number: 2000, penalty_id: 1, penalty_code_id: 1,
                   confirm_score_change: true },
         headers: token_header, as: :json
    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'a').event_id

    post "/api/v2/user/games/#{@game.id}/events/update",
         params: { event_id: 2, event_type: 'goal', event_team: 'guest', period: 1, time: '15:00',
                   home_goals: 0, guest_goals: 1, guest_number: 2000, confirm_score_change: true },
         headers: token_header, as: :json
    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'b').event_id
  end

  test 'ohne passenden Schuss bleibt das Tor unverknüpft und wird trotzdem gespeichert' do
    post_shots([shot('gast', result: 'goal', team: 'guest')])

    add_goal('home', 1, 0)

    assert_response :success
    assert_equal 1, @game.reload.events.size
    assert_nil GameShot.find_by(client_uuid: 'gast').event_id
  end

  test 'Eigentor und technisches Tor nehmen sich keinen freien Tor-Schuss' do
    post_shots([shot('frei', result: 'goal', game_time: '15:00')])

    add_goal('home', 1, 0, number: 1000)
    add_goal('home', 2, 0, goal_type: 'technical', number: 7)
    add_goal('home', 3, 0, goal_type: 'technical')

    assert_response :success
    assert_equal 3, @game.reload.events.size
    assert_nil GameShot.find_by(client_uuid: 'frei').event_id
  end

  test 'nachgereichte Tor-Schüsse übergehen Eigentor und technisches Tor, auch wenn sie zeitlich näher liegen' do
    add_goal('home', 1, 0, time: '04:00', number: 1000)
    add_goal('home', 2, 0, time: '05:00', goal_type: 'technical', number: 7)
    add_goal('home', 3, 0, time: '05:30', goal_type: 'technical')
    add_goal('home', 4, 0, time: '09:00')

    post_shots([shot('spaet', result: 'goal', game_time: '04:30')])

    assert_response :success
    assert_equal 4, GameShot.find_by(client_uuid: 'spaet').event_id
  end

  test 'wird aus dem Tor ein Eigentor oder technisches Tor, fällt die Verknüpfung weg' do
    post_shots([shot('a', result: 'goal'), shot('b', result: 'goal', at: @t0 + 1),
                shot('c', result: 'goal', at: @t0 + 2)])
    add_goal('home', 1, 0)
    add_goal('home', 2, 0)
    add_goal('home', 3, 0)
    assert_equal [1, 2, 3], GameShot.where(game: @game).order(:client_uuid).pluck(:event_id)

    post "/api/v2/user/games/#{@game.id}/events/update",
         params: { event_id: 1, event_type: 'goal', event_team: 'home', period: 1, time: '15:00',
                   home_goals: 1, guest_goals: 0, home_number: 1000, confirm_score_change: true },
         headers: token_header, as: :json
    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'a').event_id

    post "/api/v2/user/games/#{@game.id}/events/update",
         params: { event_id: 2, event_type: 'goal', event_team: 'home', period: 1, time: '15:00',
                   home_goals: 2, guest_goals: 0, home_number: 7, goal_type: 'technical',
                   confirm_score_change: true },
         headers: token_header, as: :json
    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'b').event_id

    post "/api/v2/user/games/#{@game.id}/events/update",
         params: { event_id: 3, event_type: 'goal', event_team: 'home', period: 1, time: '15:00',
                   home_goals: 3, guest_goals: 0, home_number: 2000, goal_type: 'technical',
                   confirm_score_change: true },
         headers: token_header, as: :json
    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'c').event_id
  end

  test 'von Hand lässt sich kein Schuss an ein Eigentor oder technisches Tor hängen' do
    add_goal('home', 1, 0, number: 1000)
    add_goal('home', 2, 0, goal_type: 'technical', number: 7)
    add_goal('home', 3, 0, goal_type: 'technical')
    post_shots([shot('a', result: 'goal')])

    [1, 2, 3].each do |event_id|
      post "/api/v2/games/#{@game.id}/shots/a/link.json", params: { event_id: event_id }, headers: token_header,
                                                          as: :json
      assert_response :unprocessable_entity
    end
    assert_nil GameShot.find_by(client_uuid: 'a').event_id
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
    post_shots([shot('a', result: 'goal', game_time: '02:00'), shot('b', result: 'goal', at: @t0 + 5)])
    add_goal('home', 1, 0) # verknüpft b (12:34 liegt näher an 15:00)
    assert_equal 1, GameShot.find_by(client_uuid: 'b').event_id

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

  test 'link und PATCH verlangen gleiches Team bei Schuss und Tor' do
    add_goal('guest', 0, 1)
    post_shots([shot('a', result: 'goal')])

    post "/api/v2/games/#{@game.id}/shots/a/link.json", params: { event_id: 1 }, headers: token_header, as: :json
    assert_response :unprocessable_entity

    post_shots([shot('g', result: 'goal', team: 'guest')])
    assert_equal 1, GameShot.find_by(client_uuid: 'g').event_id
    patch "/api/v2/games/#{@game.id}/shots/g.json", params: { team: 'home' }, headers: token_header, as: :json
    assert_response :unprocessable_entity
    assert_equal 'guest', GameShot.find_by(client_uuid: 'g').team
  end

  # --- Eingabeprüfung (Review api#818) -----------------------------------------

  test 'Einträge, die keine Objekte sind, sind 422 und kein 500' do
    post "/api/v2/games/#{@game.id}/shots.json", params: { shots: ['x', 3] }, headers: token_header, as: :json

    assert_response :unprocessable_entity
  end

  test 'Schütze und Torhüter müssen in der Aufstellung des richtigen Teams stehen' do
    aufstellung!
    post_shots([shot('a', shooter: 5)])
    assert_response :unprocessable_entity

    post_shots([shot('a', goalie: 77)])
    assert_response :unprocessable_entity

    post_shots([shot('a', shooter: 77, goalie: 5)])
    assert_response :success
  end

  test 'gleichzeitiges Anlegen derselben client_uuid: der Stapel wird einmal wiederholt' do
    eingaben = [shot('a', result: 'goal')]
    versuche = 0
    original = GameShot.method(:find_or_initialize_by)
    GameShot.stub(:find_or_initialize_by, lambda { |**args|
      versuche += 1
      if versuche == 1
        # Ein zweiter Request war schneller: Die Validierung sah den Schuss
        # noch nicht, der eindeutige Index schon.
        GameShot.create!(shot('a', result: 'saved').merge(game: @game))
        verlierer = GameShot.new(client_uuid: 'a')
        verlierer.define_singleton_method(:save) { |*| raise ActiveRecord::RecordNotUnique, 'doppelt' }
        return verlierer
      end
      original.call(**args)
    }) do
      post_shots(eingaben)
    end

    assert_response :success
    assert_equal 1, GameShot.where(client_uuid: 'a').count
    assert_equal 'goal', GameShot.find_by(client_uuid: 'a').result
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

  test 'detailed_stats: API-Schlüssel ohne Freigabe bekommt 403, eine Sitzung kommt durch' do
    @game.update!(ended: true)
    post_shots([shot('a')])
    raw_key, = ApiKey.generate(name: 'Ohne Paket', rate_limit: 60)

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => raw_key }
    assert_response :forbidden

    ApiKey.find_by(name: 'Ohne Paket').update!(features: %w[detailed_stats])
    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => raw_key }
    assert_response :success

    login_as(create(:user, :admin))
    get "/api/v2/games/#{@game.id}/detailed_stats.json"
    assert_response :success
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
    assert(stats['shots'].all? { |s| s.key?('event_id') })
    assert_not_includes response.body, 'Geheim'

    heim = stats['teams']['home']
    assert_equal({ 'shots' => 4, 'on_goal' => 3, 'goals' => 1, 'blocked' => 1, 'missed' => 0, 'free_hits' => 0,
                   'shots_from_free_hit' => 0, 'goals_from_free_hit' => 0, 'penalty_shots' => 0, 'goals_from_penalty_shot' => 0, 'goals_empty_net' => 0, 'goals_extra_attacker' => 0 }.merge(ohne_torhueter_null),
                 heim.except('by_period'))
    assert_equal 2, heim['by_period']['2']['shots']
    assert_equal 0, stats['teams']['guest']['by_period']['2']['shots'], 'gleiche Abschnitte für beide Teams'

    assert_equal [{ 'team' => 'guest', 'trikot_number' => 1, 'name' => 'Tim Hüter', 'saves' => 2,
                    'shots_against' => 3, 'save_pct' => 0.667,
                    'by_period' => { '1' => { 'saves' => 1, 'shots_against' => 2, 'save_pct' => 0.5 },
                                     '2' => { 'saves' => 1, 'shots_against' => 1, 'save_pct' => 1.0 } } }],
                 stats['goalkeepers']
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

  # --- Freischläge (fe#589) ----------------------------------------------------------

  test 'Freischlag: Team und Position ohne Ergebnis, in derselben Liste wie die Schüsse' do
    post_shots([shot('s'), free_hit('f', at: @t0 + 5)])

    assert_response :success
    body = response.parsed_body['shots']
    assert_equal(%w[shot free_hit], body.map { |s| s['kind'] })
    assert_nil body.last['result']
    assert_equal false, body.last['from_free_hit']
    assert_equal false, body.first['from_free_hit'], 'Schüsse ohne Angabe sind nicht aus Freischlag'
    assert @game.reload.tablet_capture?
  end

  test 'Freischlag mit Ergebnis, Spieler oder Freischlag-Schalter ist 422, Schuss ohne Ergebnis auch' do
    aufstellung!
    [{ result: 'goal' }, { shooter_player_id: 77 }, { goalkeeper_player_id: 5 }, { from_free_hit: true },
     { kind: 'corner' }].each do |falsch|
      post_shots([free_hit('f').merge(falsch)])
      assert_response :unprocessable_entity, falsch.inspect
    end

    post_shots([shot('s').merge(result: nil)])
    assert_response :unprocessable_entity
    assert_equal 0, GameShot.count
  end

  test 'Schuss aus Freischlag wird gespeichert und per PATCH geschaltet' do
    post_shots([shot('s', from_free_hit: true)])
    assert response.parsed_body['shots'].first['from_free_hit']

    patch "/api/v2/games/#{@game.id}/shots/s.json", params: { from_free_hit: false }, headers: token_header, as: :json

    assert_response :success
    assert_equal false, response.parsed_body['shots'].first['from_free_hit']
  end

  test 'ein Freischlag wird nie mit einem Tor verknüpft' do
    post_shots([free_hit('f', game_time: '15:00')])
    add_goal('home', 1, 0, time: '15:00')

    assert_response :success
    assert_nil GameShot.find_by(client_uuid: 'f').event_id

    post "/api/v2/games/#{@game.id}/shots/f/link.json", params: { event_id: 1 }, headers: token_header, as: :json
    assert_response :unprocessable_entity
  end

  test 'detailed_stats: Freischläge zählen nicht als Schuss, Schüsse und Tore aus Freischlag getrennt' do
    @game.update!(ended: true)
    post_shots([
      free_hit('f1'),
      shot('s1', result: 'goal', from_free_hit: true, at: @t0 + 5),
      shot('s2', result: 'saved', from_free_hit: true, at: @t0 + 10),
      shot('s3', result: 'missed', at: @t0 + 15),
      free_hit('f2', at: @t0 + 20, period: 3, team: 'guest')
    ])

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    stats = response.parsed_body
    assert_equal 3, stats['shots'].size
    assert_equal [true, true, false], stats['shots'].pluck('from_free_hit')
    assert_equal [{ 'team' => 'home', 'period' => 1, 'game_time' => '12:34', 'x' => 0.8, 'y' => 0.4 },
                  { 'team' => 'guest', 'period' => 3, 'game_time' => '12:34', 'x' => 0.8, 'y' => 0.4 }],
                 stats['free_hits']

    heim = stats['teams']['home']
    assert_equal({ 'shots' => 3, 'on_goal' => 2, 'goals' => 1, 'blocked' => 0, 'missed' => 1, 'free_hits' => 1,
                   'shots_from_free_hit' => 2, 'goals_from_free_hit' => 1, 'penalty_shots' => 0, 'goals_from_penalty_shot' => 0, 'goals_empty_net' => 0, 'goals_extra_attacker' => 0 }.merge(ohne_torhueter_null),
                 heim.except('by_period'))
    assert_equal %w[1 3], heim['by_period'].keys, 'Abschnitte nur mit Freischlag zählen mit'
    assert_equal 1, stats['teams']['guest']['by_period']['3']['free_hits']
    assert_equal 0, stats['teams']['guest']['shots']
    assert_empty stats['goalkeepers']
  end

  # --- Szene vormerken (fe#560) ------------------------------------------------------

  test 'vorgemerkte Szene ohne Team und Position, zählt nirgends in der Statistik' do
    post_shots([shot('a', result: 'goal'),
                { client_uuid: 'm', kind: 'mark', period: 1, game_time: '05:00', tapped_at: @t0.utc.iso8601(3) }])

    assert_response :success
    marke = response.parsed_body['shots'].find { |s| s['client_uuid'] == 'm' }
    assert_equal ['mark', nil, nil, nil, true], marke.values_at('kind', 'team', 'x', 'result', 'in_highlights')

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }
    body = response.parsed_body
    assert_equal 1, body['shots'].size
    assert_empty body['free_hits']
  end

  test 'vorgemerkte Szene mit Ergebnis oder Spieler wird abgewiesen' do
    post_shots([{ client_uuid: 'm', kind: 'mark', period: 1, tapped_at: @t0.utc.iso8601(3), result: 'goal' }])

    assert_response :unprocessable_entity
  end

  test 'ein Schuss braucht weiter Team und Position' do
    post_shots([shot('a').except(:team)])
    assert_response :unprocessable_entity

    post_shots([shot('a').except(:x)])
    assert_response :unprocessable_entity
  end

  # --- Strafschüsse, Torwartsituation, Paraden ohne Position (Feedback #61-#64) ---

  test 'Strafschuss und Torwartsituation werden gespeichert, ausgegeben und per PATCH geschaltet' do
    post_shots([shot('p', result: 'saved', from_penalty_shot: true),
                shot('e', result: 'goal', empty_net: true, extra_attacker: true, at: @t0 + 5),
                shot('n', at: @t0 + 10)])

    assert_response :success
    body = response.parsed_body['shots'].index_by { |s| s['client_uuid'] }
    assert_equal [true, false, false], body['p'].values_at('from_penalty_shot', 'empty_net', 'extra_attacker')
    assert_equal [false, true, true], body['e'].values_at('from_penalty_shot', 'empty_net', 'extra_attacker')
    assert_equal [false, false, false], body['n'].values_at('from_penalty_shot', 'empty_net', 'extra_attacker'),
                 'ohne Angabe gilt keine Kennung'

    patch "/api/v2/games/#{@game.id}/shots/e.json", params: { empty_net: false }, headers: token_header, as: :json

    assert_response :success
    assert_equal false, GameShot.find_by(client_uuid: 'e').empty_net
    assert GameShot.find_by(client_uuid: 'e').extra_attacker
  end

  test 'Strafschuss: Widersprüche werden angeglichen, das Ergebnis gewinnt' do
    post_shots([shot('a', from_penalty_shot: true, from_free_hit: true),
                shot('b', from_penalty_shot: true, result: 'blocked', at: @t0 + 1),
                shot('c', from_penalty_shot: true, result: 'goal', empty_net: true, extra_attacker: true, at: @t0 + 2)])

    assert_response :success
    flags = GameShot.order(:client_uuid).map { |s| [s.from_penalty_shot, s.from_free_hit, s.empty_net, s.extra_attacker] }
    assert_equal [[false, true, false, false], [false, false, false, false], [true, false, false, false]], flags
  end

  test 'leeres Tor: gesetzter Torhüter oder gehalten nehmen es zurück' do
    aufstellung!
    post_shots([shot('e', result: 'goal', empty_net: true, goalie: 5),
                shot('f', result: 'saved', empty_net: true, at: @t0 + 1),
                shot('g', result: 'missed', empty_net: true, at: @t0 + 2)])

    assert_response :success
    assert_equal({ 'e' => false, 'f' => false, 'g' => true }, GameShot.pluck(:client_uuid, :empty_net).to_h)
  end

  test 'älteres Tablet ohne die Kennungen hängt nicht an einem Serverwert fest' do
    aufstellung!
    post_shots([shot('e', result: 'goal', empty_net: true)])
    assert_response :success

    # Gerät ohne die neuen Schlüssel schickt denselben Schuss als gehalten mit Torhüter.
    post_shots([shot('e', result: 'saved', goalie: 5)])

    assert_response :success
    schuss = GameShot.find_by(client_uuid: 'e')
    assert_equal ['saved', 5, false], [schuss.result, schuss.goalkeeper_player_id, schuss.empty_net]

    post_shots([shot('p', result: 'saved', from_penalty_shot: true, at: @t0 + 1)])
    post_shots([shot('p', result: 'blocked', at: @t0 + 1)])
    assert_response :success
    assert_equal false, GameShot.find_by(client_uuid: 'p').from_penalty_shot
  end

  test 'Kennungen der Schüsse gibt es an Freischlag und vorgemerkter Szene nicht' do
    %i[from_penalty_shot empty_net extra_attacker].each do |flag|
      post_shots([free_hit('f').merge(flag => true)])
      assert_response :unprocessable_entity, flag.to_s

      post_shots([{ client_uuid: 'm', kind: 'mark', period: 1, tapped_at: @t0.utc.iso8601(3), flag => true }])
      assert_response :unprocessable_entity, flag.to_s
    end
  end

  test 'Parade ohne Position nur bei gehaltenem Schuss ohne Strafschuss' do
    post_shots([shot('s').merge(x: nil, y: nil)])
    assert_response :success
    assert_nil response.parsed_body['shots'].first['x']

    post_shots([shot('g', result: 'goal').merge(x: nil, y: nil)])
    assert_response :unprocessable_entity

    post_shots([shot('p', from_penalty_shot: true).merge(x: nil, y: nil)])
    assert_response :unprocessable_entity

    post_shots([shot('h').merge(y: nil)])
    assert_response :unprocessable_entity, 'nur eine Koordinate ist keine Parade ohne Position'
  end

  test 'detailed_stats: Strafschüsse, leeres Tor und 6 gegen 5 je Team, Paraden ohne Position beim Torhüter' do
    aufstellung!
    @game.update!(ended: true)
    post_shots([
      shot('p1', result: 'goal', from_penalty_shot: true, goalie: 5),
      shot('p2', result: 'saved', from_penalty_shot: true, goalie: 5, at: @t0 + 5),
      shot('e1', result: 'goal', empty_net: true, at: @t0 + 10, period: 3),
      shot('x1', result: 'goal', extra_attacker: true, goalie: 5, at: @t0 + 15, period: 3),
      shot('u1', goalie: 5, at: @t0 + 20, period: 2).merge(x: nil, y: nil),
      shot('u2', goalie: 5, at: @t0 + 25, period: 2).merge(x: nil, y: nil)
    ])
    assert_response :success

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    stats = response.parsed_body
    assert_equal 6, stats['shots'].size
    assert_equal 2, stats['shots'].count { |s| s['x'].nil? && s['y'].nil? }, 'Paraden ohne Position ohne Koordinaten'
    assert_equal [true, true, false, false, false, false], stats['shots'].pluck('from_penalty_shot')
    assert_equal [false, false, true, false, false, false], stats['shots'].pluck('empty_net')
    assert_equal [false, false, false, true, false, false], stats['shots'].pluck('extra_attacker')

    heim = stats['teams']['home']
    assert_equal({ 'shots' => 6, 'on_goal' => 6, 'goals' => 3, 'penalty_shots' => 2, 'goals_from_penalty_shot' => 1,
                   'goals_empty_net' => 1, 'goals_extra_attacker' => 1 },
                 heim.slice('shots', 'on_goal', 'goals', 'penalty_shots', 'goals_from_penalty_shot',
                            'goals_empty_net', 'goals_extra_attacker'))
    assert_equal [1, 1], heim['by_period']['3'].values_at('goals_empty_net', 'goals_extra_attacker')
    assert_equal 0, heim['by_period']['1']['goals_empty_net']

    torhueter = stats['goalkeepers'].sole
    assert_equal ['guest', 3, 5, 0.6], torhueter.values_at('team', 'saves', 'shots_against', 'save_pct'),
                 'das Tor aufs leere Tor belastet den Torhüter nicht, Paraden ohne Position zählen'
    assert_equal({ '1' => { 'saves' => 1, 'shots_against' => 2, 'save_pct' => 0.5 },
                   '2' => { 'saves' => 2, 'shots_against' => 2, 'save_pct' => 1.0 },
                   '3' => { 'saves' => 0, 'shots_against' => 1, 'save_pct' => 0.0 } }, torhueter['by_period'])
  end

  test 'detailed_stats: Tore ohne eigenen Torhüter nach Spielstärke aus den laufenden Strafen (fe#610)' do
    aufstellung!
    @game.update!(ended: true, events: [
      { 'id' => 1, 'period' => 3, 'time' => '10:00', 'event_team' => 'guest', 'guest_number' => 1,
        'penalty_id' => '1', 'penalty_code_id' => '1', 'penalty_mapping' => 'penalty_2' },
      { 'id' => 2, 'period' => 3, 'time' => '11:20', 'event_team' => 'home', 'home_number' => 7,
        'penalty_id' => '1', 'penalty_code_id' => '1', 'penalty_mapping' => 'penalty_2' }
    ])
    post_shots([
      shot('a', result: 'goal', extra_attacker: true, period: 3, game_time: '9:00'),
      shot('b', result: 'goal', extra_attacker: true, period: 3, game_time: '11:00', at: @t0 + 5),
      shot('c', result: 'goal', extra_attacker: true, period: 3, game_time: nil, at: @t0 + 10),
      shot('d', result: 'saved', extra_attacker: true, period: 3, game_time: '11:30', at: @t0 + 15),
      shot('e', result: 'goal', extra_attacker: true, period: 3, game_time: '11:40', at: @t0 + 20)
    ])
    assert_response :success

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    stats = response.parsed_body
    assert_equal ['6v5', '6v4', nil, '5v4', '5v4'], stats['shots'].pluck('extra_attacker_strength'),
                 'ohne Spielzeit unbekannt, auch ein gehaltener Schuss trägt die Stärke'
    erwartet = { 'goals_extra_attacker' => 4, 'goals_extra_attacker_6v5' => 1, 'goals_extra_attacker_6v4' => 1,
                 'goals_extra_attacker_other' => 1, 'goals_extra_attacker_unknown' => 1 }
    assert_equal erwartet, stats['teams']['home'].slice(*erwartet.keys)
    assert_equal erwartet, stats['teams']['home']['by_period']['3'].slice(*erwartet.keys)
    assert_equal 0, stats['teams']['guest']['goals_extra_attacker_6v4']
  end

  test 'detailed_stats: Torhüterwechsel, Abschnitt ohne Einsatz ist 0 von 0 ohne Quote' do
    @game.update!(ended: true, players: {
                    'home' => [{ 'player_id' => 77, 'trikot_number' => 7, 'player_firstname' => 'A', 'player_name' => 'B' }],
                    'guest' => [{ 'player_id' => 5, 'trikot_number' => 1, 'player_firstname' => 'C', 'player_name' => 'D' },
                                { 'player_id' => 6, 'trikot_number' => 30, 'player_firstname' => 'E', 'player_name' => 'F' }]
                  })
    post_shots([shot('a', goalie: 5), shot('b', result: 'goal', goalie: 5, at: @t0 + 5),
                shot('c', goalie: 6, at: @t0 + 10, period: 2)])

    get "/api/v2/games/#{@game.id}/detailed_stats.json", headers: { 'X-Api-Key' => API_KEY }

    torhueter = response.parsed_body['goalkeepers'].index_by { |gk| gk['trikot_number'] }
    assert_equal({ '1' => { 'saves' => 1, 'shots_against' => 2, 'save_pct' => 0.5 },
                   '2' => { 'saves' => 0, 'shots_against' => 0, 'save_pct' => nil } }, torhueter[1]['by_period'])
    assert_equal({ '1' => { 'saves' => 0, 'shots_against' => 0, 'save_pct' => nil },
                   '2' => { 'saves' => 1, 'shots_against' => 1, 'save_pct' => 1.0 } }, torhueter[30]['by_period'])
  end

  test 'das Tablet überschreibt die Highlight-Auswahl nicht' do
    post_shots([shot('a', result: 'goal')])
    GameShot.find_by(client_uuid: 'a').update!(in_highlights: false)

    post_shots([shot('a', result: 'goal').merge(in_highlights: true)])

    assert_not GameShot.find_by(client_uuid: 'a').in_highlights
  end

  # --- Rückmeldung zur Beta (fe#560) ------------------------------------------------

  test 'Rückmeldung per Sekretariats-Link geht an das Postfach, Reply-To ist die angegebene Adresse' do
    post_shots([shot('a')])
    assert_emails 1 do
      post "/api/v2/games/#{@game.id}/tablet_feedback.json",
           params: { message: "Knöpfe zu klein\n<b>fett</b>", reply_to: 'erfasser@example.de', device: 'iPad 1024x768' },
           headers: token_header, as: :json
      assert_response :accepted
    end

    mail = ActionMailer::Base.deliveries.last
    assert_equal [TabletFeedbackMailer::NOTIFY_EMAIL], mail.to
    assert_equal ['erfasser@example.de'], mail.reply_to
    body = mail.html_part&.body&.to_s || mail.body.to_s
    assert_includes body, 'Knöpfe zu klein'
    assert_includes body, '&lt;b&gt;fett&lt;/b&gt;', 'Freitext wird escaped'
    assert_includes body, "Sekretariats-Link ##{@link.id}"
    assert_includes body, 'iPad 1024x768'
    assert_includes body, @game.url
    assert_match(%r{Erfasste Schüsse:</strong> 1}, body)
    assert_match(%r{Erfasste Freischläge:</strong> 0}, body)
  end

  test 'Rückmeldung ohne Antwortadresse nimmt die des Kontos, auch nach dem Abschluss' do
    vm = create(:user, :vm, club_id: @club.id, email: 'vm@example.de')
    @game.update!(game_status: 'match_record_closed')
    login_as(vm)

    assert_emails 1 do
      post "/api/v2/games/#{@game.id}/tablet_feedback.json", params: { message: 'Lief gut' }, as: :json
      assert_response :accepted
    end
    assert_equal ['vm@example.de'], ActionMailer::Base.deliveries.last.reply_to
  end

  test 'Rückmeldung: leer, zu lang oder ungültige Adresse ist 422' do
    [{ message: '  ' },
     { message: 'x' * (GameShotsController::FEEDBACK_MAX_LENGTH + 1) },
     { message: 'ok', reply_to: 'keine-adresse' }].each do |eingabe|
      assert_no_emails do
        post "/api/v2/games/#{@game.id}/tablet_feedback.json", params: eingabe, headers: token_header, as: :json
      end
      assert_response :unprocessable_entity
    end
  end

  test 'Rückmeldung nur mit Zugriff auf den Spielbericht' do
    assert_no_emails do
      post "/api/v2/games/#{@game.id}/tablet_feedback.json", params: { message: 'x' }, as: :json
      assert_response :unauthorized

      post "/api/v2/games/#{@foreign_game.id}/tablet_feedback.json", params: { message: 'x' },
                                                                      headers: token_header, as: :json
      assert_response :forbidden
    end
  end

  # Gezählt wird vor der Anmeldung (rack_attack.rb, Topf 'tablet-feedback/ip').
  # Alle Schreibweisen, die der Router in die Action lässt, zählen in denselben
  # Topf: mit und ohne Endung, fremde Endung, Schrägstrich am Ende.
  test 'Rückmeldung: nach zehn Anfragen in der Stunde wird gebremst, gleich in welcher Schreibweise' do
    basis = "/api/v2/games/#{@game.id}/tablet_feedback"
    varianten = ["#{basis}.json", basis, "#{basis}/", "#{basis}.xml", "#{basis}.txt"]
    travel_to Time.zone.now.beginning_of_hour do
      10.times { |i| post varianten[i % varianten.size], params: { message: 'x' }, as: :json }
      assert_response :unauthorized

      varianten.each do |pfad|
        post pfad, params: { message: 'x' }, as: :json
        assert_response :too_many_requests, pfad
      end
    end
  end

  test 'Rückmeldung: angemeldet ohne Recht am Spiel ist 403' do
    login_as(create(:user, :vm, club_id: create(:club).id))

    assert_no_emails do
      post "/api/v2/games/#{@game.id}/tablet_feedback.json", params: { message: 'x' }, as: :json
    end
    assert_response :forbidden
  end

  # Kein pflegbarer Body: Eine Vorlage in der Verwaltung darf weder den Freitext
  # verdrängen noch das Reply-To umbiegen (Review api#832).
  test 'Rückmeldung: gepflegte Mailvorlagen greifen nicht' do
    assert_nil EmailTemplateCatalog.find('TabletFeedbackMailer', 'feedback')

    assert_emails 1 do
      post "/api/v2/games/#{@game.id}/tablet_feedback.json",
           params: { message: 'Knöpfe zu klein', reply_to: 'erfasser@example.de' }, headers: token_header, as: :json
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal ['erfasser@example.de'], mail.reply_to
    assert_includes mail.subject, 'Tabletmodus-Rückmeldung'
  end

  private

  def ohne_torhueter_null
    %w[6v5 6v4 other unknown].to_h { |gruppe| ["goals_extra_attacker_#{gruppe}", 0] }
  end

  def build_game(game_day)
    Game.create!(game_day: game_day,
                 home_team: create(:team, league: @league, club: @club),
                 guest_team: create(:team, league: @league, club: create(:club)),
                 forfait: 0, overtime: false, legacy: false, events: [],
                 players: { 'home' => [], 'guest' => [] })
  end

  def aufstellung!
    @game.update!(players: {
                    'home' => [{ 'player_id' => 77, 'trikot_number' => 7, 'player_firstname' => 'A', 'player_name' => 'B' }],
                    'guest' => [{ 'player_id' => 5, 'trikot_number' => 1, 'player_firstname' => 'C', 'player_name' => 'D' }]
                  })
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

  SHOT_FLAGS = %i[from_free_hit from_penalty_shot empty_net extra_attacker].freeze

  SHOT_DEFAULTS = { result: 'saved', team: 'home', pos_x: 0.8, period: 1, shooter: nil, goalie: nil,
                    game_time: '12:34' }.freeze

  def shot(uuid, at: @t0, **optionen)
    o = SHOT_DEFAULTS.merge(optionen)
    { client_uuid: uuid, team: o[:team], period: o[:period], game_time: o[:game_time],
      tapped_at: at.utc.iso8601(3), x: o[:pos_x], y: 0.4, result: o[:result],
      shooter_player_id: o[:shooter], goalkeeper_player_id: o[:goalie] }.merge(optionen.slice(*SHOT_FLAGS))
  end

  # Optionen wie bei `shot`, nur ohne Ergebnis und Spieler.
  def free_hit(uuid, at: @t0, **optionen)
    shot(uuid, at: at, **optionen).except(:result, :shooter_player_id, :goalkeeper_player_id).merge(kind: 'free_hit')
  end

  # `number: 1000` ist ein Eigentor. Ein technisches Tor (`goal_type: 'technical'`)
  # mit 2000 zeigt formatted_events als „nicht angegeben“; einen Schuss bekommt
  # es trotzdem nicht.
  def add_goal(team, home, guest, time: '15:00', period: 1, confirm: false, number: 2000, goal_type: nil)
    post "/api/v2/user/games/#{@game.id}/events/add",
         params: { event_type: 'goal', event_team: team, period: period, time: time, home_goals: home,
                   guest_goals: guest, "#{team}_number": number, goal_type: goal_type,
                   confirm_score_change: confirm }.compact,
         headers: token_header, as: :json
  end
end
