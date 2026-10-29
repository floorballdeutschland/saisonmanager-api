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

  private

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
