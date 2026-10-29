require 'test_helper'

# Schussstatistik einer Liga, Zusatzpaket `league_shot_stats` (LeagueShotStats).
class LeagueShotStatsTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    sa = create(:state_association)
    @league = create(:league, game_operation: create(:game_operation, state_association_id: sa.id))
    @club = create(:club, state_association_id: sa.id)
    @arena = create(:arena)
    @a = create(:team, league: @league, club: @club, name: 'Adler')
    @b = create(:team, league: @league, club: create(:club), name: 'Bären')
    @t0 = Time.zone.parse('2026-10-11 18:10:00 +02:00')

    @g1 = spiel(1, @a, @b, ended: true, capture: true)
    @g2 = spiel(2, @b, @a, ended: true, capture: true)
    spiel(3, @a, @b, ended: true, capture: false)
    @laufend = spiel(4, @a, @b, ended: false, capture: true)

    schuss(@g1, 'home', 'goal', shooter: 11, goalie: 22)
    schuss(@g1, 'home', 'saved', shooter: 11, goalie: 22)
    schuss(@g1, 'guest', 'missed', shooter: 21)
    schuss(@g1, 'guest', 'saved', shooter: 21, goalie: 12)
    schuss(@g2, 'guest', 'goal', shooter: 11, empty_net: true)
    schuss(@g2, 'home', 'saved', shooter: 21, goalie: 12)
    schuss(@laufend, 'home', 'goal', shooter: 11, goalie: 22)
  end

  test 'summiert Mannschaften, Schützen und Torhüter über die erfassten, beendeten Spiele' do
    get "/api/v2/leagues/#{@league.id}/shot_stats.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    stats = response.parsed_body
    assert_equal [3, 2, 0], stats.values_at('games_ended', 'games_captured', 'games_complete')

    adler = stats['teams'].find { |t| t['team_id'] == @a.id }
    assert_equal({ 'team_name' => 'Adler', 'games' => 2, 'shots' => 3, 'on_goal' => 3, 'goals' => 2, 'missed' => 0,
                   'goals_empty_net' => 1, 'shots_against' => 3, 'on_goal_against' => 2, 'goals_against' => 0 },
                 adler.slice('team_name', 'games', 'shots', 'on_goal', 'goals', 'missed', 'goals_empty_net',
                             'shots_against', 'on_goal_against', 'goals_against'))
    assert_equal(%w[Adler Bären], stats['teams'].map { |t| t['team_name'] })

    assert_equal [{ 'player_id' => 11, 'team_id' => @a.id, 'team_name' => 'Adler', 'trikot_number' => 9,
                    'name' => 'Anna Schuss', 'games' => 2, 'shots' => 3, 'on_goal' => 3, 'goals' => 2,
                    'shooting_pct' => 0.667 },
                  { 'player_id' => 21, 'team_id' => @b.id, 'team_name' => 'Bären', 'trikot_number' => 8,
                    'name' => 'Bea Ball', 'games' => 2, 'shots' => 3, 'on_goal' => 2, 'goals' => 0,
                    'shooting_pct' => 0.0 }],
                 stats['players']

    werte = %w[player_id games saves shots_against goals_against save_pct]
    assert_equal([[12, 2, 2, 2, 0, 1.0], [22, 1, 1, 2, 1, 0.5]], stats['goalkeepers'].map { |g| g.values_at(*werte) })
  end

  test 'Namen in öffentlicher Anzeigeform' do
    versteckt = create(:player, first_name: 'Anna', last_name: 'Geheim', public_last_name_hidden_at: Time.current)
    @g1.update!(players: lineup(home: [[versteckt.id, 9, 'Anna', 'Geheim']], guest: []))
    @g2.update!(players: lineup(home: [], guest: []))
    GameShot.where(game: @g1).update_all(shooter_player_id: versteckt.id, goalkeeper_player_id: nil)
    PublicPlayerNames.flush!

    get "/api/v2/leagues/#{@league.id}/shot_stats.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_not_includes response.body, 'Geheim'
    assert_equal 'Anna', response.parsed_body['players'].find { |p| p['player_id'] == versteckt.id }['name']
  end

  test 'API-Schlüssel ohne Freigabe bekommt 403, ohne Schlüssel 401, eine Sitzung kommt durch' do
    get "/api/v2/leagues/#{@league.id}/shot_stats.json"
    assert_response :unauthorized

    raw_key, = ApiKey.generate(name: 'Nur Spiel', rate_limit: 60)
    ApiKey.find_by(name: 'Nur Spiel').update!(features: %w[detailed_stats])
    get "/api/v2/leagues/#{@league.id}/shot_stats.json", headers: { 'X-Api-Key' => raw_key }
    assert_response :forbidden

    admin = create(:user, :admin)
    post '/api/v2/login', params: { username: admin.user_name, password: 'password123' }, as: :json
    get "/api/v2/leagues/#{@league.id}/shot_stats.json"
    assert_response :success
  end

  test 'ein neuer Schuss und ein geändertes Spiel leeren den Zwischenspeicher' do
    with_real_cache do
      abruf = lambda do
        get "/api/v2/leagues/#{@league.id}/shot_stats.json", headers: { 'X-Api-Key' => API_KEY }
        response.parsed_body
      end
      assert_equal 3, abruf.call['teams'].find { |t| t['team_id'] == @a.id }['shots']

      schuss(@g2, 'guest', 'missed', shooter: 11)
      GameShotStats.flush!(@g2)
      assert_equal 4, abruf.call['teams'].find { |t| t['team_id'] == @a.id }['shots']

      @g2.update!(tablet_shots_complete: true)
      assert_equal 1, abruf.call['games_complete']
    end
  end

  test 'Einsätze kommen aus der Aufstellung, nicht aus den Spielen mit Schuss' do
    schuss(@g1, 'home', 'missed', shooter: 12)

    eintrag = abruf['players'].find { |p| p['player_id'] == 12 }

    assert_equal [2, 1], eintrag.values_at('games', 'shots'), 'in beiden Aufstellungen, nur in g1 geschossen'
  end

  test 'Forfaitspiele zählen weder als beendet noch in den Summen' do
    forfait = spiel(5, @a, @b, ended: true, capture: true)
    schuss(forfait, 'home', 'goal', shooter: 11, goalie: 22)
    forfait.update_columns(forfait: 1)

    stats = abruf

    assert_equal [3, 2], stats.values_at('games_ended', 'games_captured')
    assert_equal 3, stats['teams'].find { |t| t['team_id'] == @a.id }['shots']
  end

  test 'Schütze außerhalb der Aufstellung zählt nur in der Teamsumme' do
    GameShot.where(game: @g1, shooter_player_id: 21).update_all(shooter_player_id: 99, goalkeeper_player_id: 98)

    stats = abruf

    assert_nil(stats['players'].find { |p| p['player_id'] == 99 })
    assert_equal 1, stats['players'].find { |p| p['player_id'] == 21 }['shots'], 'g1 fällt weg, g2 bleibt'
    assert_equal 3, stats['teams'].find { |t| t['team_id'] == @b.id }['shots']
    assert_nil(stats['goalkeepers'].find { |g| g['player_id'] == 98 })
  end

  test 'ein Spiel ohne Gastmannschaft zählt nur für die Heimseite' do
    ohne_gast = spiel(5, @a, @b, ended: true, capture: true)
    schuss(ohne_gast, 'home', 'missed', shooter: 11)
    schuss(ohne_gast, 'guest', 'saved', shooter: 21, goalie: 12)
    ohne_gast.update_columns(guest_team_id: nil)

    stats = abruf

    assert_response :success
    assert_equal [3, 4], stats['teams'].find { |t| t['team_id'] == @a.id }.values_at('games', 'shots')
    assert_equal 2, stats['teams'].find { |t| t['team_id'] == @b.id }['games']
    assert_equal 3, stats['players'].find { |p| p['player_id'] == 21 }['shots'], 'Schuss ohne Mannschaft fällt weg'
  end

  test 'wer die Mannschaft wechselt, steht je Mannschaft getrennt' do
    wechsel = spiel(5, @b, @a, ended: true, capture: true)
    wechsel.update!(players: lineup(home: [[11, 4, 'Anna', 'Schuss']] + b_lineup, guest: a_lineup.drop(1)))
    schuss(wechsel, 'home', 'goal', shooter: 11)

    eintraege = abruf['players'].select { |p| p['player_id'] == 11 }

    assert_equal [[@a.id, 2, 3, 9], [@b.id, 1, 1, 4]],
                 eintraege.map { |e| e.values_at('team_id', 'games', 'shots', 'trikot_number') }.sort
  end

  test 'Ausblenden des Nachnamens leert die Schussstatistik sofort' do
    spieler = create(:player, first_name: 'Anna', last_name: 'Schuss')
    [@g1, @g2].each do |game|
      game.update!(players: game.players.transform_values do |eintraege|
        eintraege.map { |e| e['player_id'] == 11 ? e.merge('player_id' => spieler.id) : e }
      end)
    end
    GameShot.where(shooter_player_id: 11).update_all(shooter_player_id: spieler.id)

    with_real_cache do
      assert_includes abruf['players'].map { |p| p['name'] }, 'Anna Schuss'

      spieler.hide_public_last_name!(create(:user, :admin).id)

      assert_includes abruf['players'].map { |p| p['name'] }, 'Anna'
      assert_not_includes response.body, 'Schuss'
    end
  end

  private

  def abruf
    get "/api/v2/leagues/#{@league.id}/shot_stats.json", headers: { 'X-Api-Key' => API_KEY }
    assert_response :success
    response.parsed_body
  end

  def spiel(number, home, guest, ended:, capture:)
    day = GameDay.create!(league: @league, arena: @arena, club: @club, number: number,
                          date: Date.new(2026, 10, 10) + number.weeks)
    players = if home == @a
                lineup(home: a_lineup, guest: b_lineup)
              else
                lineup(home: b_lineup, guest: a_lineup)
              end
    Game.create!(game_day: day, home_team: home, guest_team: guest, game_number: number.to_s,
                 forfait: 0, overtime: false, legacy: false, events: [], ended: ended, players: players,
                 tablet_capture_at: capture ? @t0 : nil)
  end

  def a_lineup
    [[11, 9, 'Anna', 'Schuss'], [12, 1, 'Gina', 'Keeper']]
  end

  def b_lineup
    [[21, 8, 'Bea', 'Ball'], [22, 1, 'Hans', 'Wand']]
  end

  def lineup(home:, guest:)
    eintrag = lambda do |(id, nummer, vorname, name)|
      { 'player_id' => id, 'trikot_number' => nummer, 'player_firstname' => vorname, 'player_name' => name }
    end
    { 'home' => home.map(&eintrag), 'guest' => guest.map(&eintrag) }
  end

  def schuss(game, team, result, shooter: nil, goalie: nil, empty_net: false)
    @n = (@n || 0) + 1
    GameShot.create!(game: game, client_uuid: "s#{@n}", kind: 'shot', team: team, period: 1, game_time: '10:00',
                     tapped_at: @t0 + @n, x: 0.8, y: 0.4, result: result, shooter_player_id: shooter,
                     goalkeeper_player_id: goalie, empty_net: empty_net)
  end
end
