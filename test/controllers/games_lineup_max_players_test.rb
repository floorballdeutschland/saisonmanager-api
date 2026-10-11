require 'test_helper'

# Kadergröße im Spielbericht (api#784): höchstens 20 Spieler je Mannschaft im
# Großfeld, 14 im Kleinfeld. Gilt für alle Rollen, auch Admin. Freitext-Einträge
# zählen mit, Trainer nicht.
class GamesLineupMaxPlayersTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league', field_size: 'KF')
    @club = create(:club, game_operation: @go)
    @team = create(:team, league: @league, club: @club)
    @opponent = create(:team, league: @league, club: create(:club))
    @game = game_on('2026-01-17')

    login(create(:user, :admin))
  end

  test 'im Kleinfeld wird der 15. Spieler abgewiesen, auch vom Admin' do
    @game.update!(players: { 'home' => free_text_entries(14), 'guest' => [] })

    post add_path('home'), params: { player_id: licensed_player.id, trikot_number: 99 }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'Kader voll: Im Kleinfeld sind höchstens 14 Spieler erlaubt.',
                 JSON.parse(response.body)['message']
    assert_equal 14, @game.reload.players['home'].size
  end

  test 'der 14. Spieler kommt noch hinein' do
    @game.update!(players: { 'home' => free_text_entries(13), 'guest' => [] })

    post add_path('home'), params: { player_id: licensed_player.id, trikot_number: 99 }, as: :json

    assert_response :success
    assert_equal 14, @game.reload.players['home'].size
  end

  test 'Freitext-Einträge werden ebenfalls abgewiesen' do
    @game.update!(players: { 'home' => free_text_entries(14), 'guest' => [] })

    post add_path('home'), params: { player_firstname: 'Frei', player_name: 'Text', trikot_number: 99 }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'Kader voll: Im Kleinfeld sind höchstens 14 Spieler erlaubt.',
                 JSON.parse(response.body)['message']
    assert_equal 14, @game.reload.players['home'].size
  end

  test 'eine unbekannte Seite wird abgewiesen statt neben dem Kader abgelegt' do
    post add_path('heim'), params: { player_id: licensed_player.id, trikot_number: 99 }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'Seite fehlt oder ist unbekannt (erlaubt: Heim oder Gast).', JSON.parse(response.body)['message']
    assert_equal %w[guest home], @game.reload.players.keys.sort
  end

  test 'eine Playoff-Liga ohne Feldgröße erbt die Grenze der Hauptrunde' do
    playoff = create(:league, :current_season, game_operation: @go, league_modus: 'playoff', field_size: nil,
                                               league_id_preround: @league.id)
    playoff_team = create(:team, league: playoff, club: @club)
    game_day = GameDay.create!(league: playoff, arena: create(:arena), club: @club, number: 1, date: '2026-03-14')
    game = Game.create!(game_day:, home_team: playoff_team, guest_team: create(:team, league: playoff),
                        start_time: '14:00', forfait: 0, overtime: false, legacy: false, events: [],
                        players: { 'home' => free_text_entries(14), 'guest' => [] })
    player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                             with_licenses: [{ team: playoff_team, status: License::APPROVED }])

    post "/api/v2/user/games/#{game.id}/lineup/home/add_player",
         params: { player_id: player.id, trikot_number: 99 }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'Kader voll: Im Kleinfeld sind höchstens 14 Spieler erlaubt.',
                 JSON.parse(response.body)['message']
  end

  test 'die Gegenseite zählt nicht mit' do
    @game.update!(players: { 'home' => free_text_entries(14), 'guest' => [] })
    guest = create(:player, clubs: [{ 'club_id' => @opponent.club_id, 'home_club' => true }],
                            with_licenses: [{ team: @opponent, status: License::APPROVED }])

    post add_path('guest'), params: { player_id: guest.id, trikot_number: 7 }, as: :json

    assert_response :success
  end

  test 'im Großfeld liegt die Grenze bei 20' do
    @league.update!(field_size: 'GF')
    @game.update!(players: { 'home' => free_text_entries(20), 'guest' => [] })

    post add_path('home'), params: { player_id: licensed_player.id, trikot_number: 99 }, as: :json

    assert_response :unprocessable_entity
    assert_match(/Großfeld sind höchstens 20/, JSON.parse(response.body)['message'])
  end

  test 'ohne Feldgröße gibt es keine Grenze' do
    @league.update!(field_size: nil)
    @game.update!(players: { 'home' => free_text_entries(25), 'guest' => [] })

    post add_path('home'), params: { player_id: licensed_player.id, trikot_number: 99 }, as: :json

    assert_response :success
    assert_equal 26, @game.reload.players['home'].size
  end

  test 'die Übernahme aus dem letzten Spiel füllt nur bis zur Grenze auf' do
    @game.update!(players: { 'home' => free_text_entries(12), 'guest' => [] })
    players = Array.new(4) { |i| licensed_player("Name#{i}") }
    game_on('2026-01-10', home_players: players.each_with_index.map { |p, i| entry(p, 50 + i) })

    post "/api/v2/user/games/#{@game.id}/lineup/home/copy_from_last_game"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body['added_count']
    assert_equal([[52, 'Kader voll (höchstens 14)'], [53, 'Kader voll (höchstens 14)']],
                 body['skipped'].map { |s| [s['trikot_number'], s['reason']] })
    assert_equal 14, @game.reload.players['home'].size
  end

  test 'bei der Übernahme schlägt der eigentliche Grund das volle Kader' do
    @game.update!(players: { 'home' => free_text_entries(13), 'guest' => [] })
    unlicensed = create(:player, last_name: 'OhneLizenz', clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    game_on('2026-01-10', home_players: [entry(licensed_player('Erster'), 50), entry(unlicensed, 51),
                                         entry(licensed_player('Doppelnummer'), 1),
                                         entry(licensed_player('Letzter'), 52)])

    post "/api/v2/user/games/#{@game.id}/lineup/home/copy_from_last_game"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body['added_count']
    assert_equal([[51, 'kein Lizenzantrag für diese Mannschaft'], [1, 'Nummer 1 bereits vergeben'],
                  [52, 'Kader voll (höchstens 14)']],
                 body['skipped'].map { |s| [s['trikot_number'], s['reason']] })
  end

  test 'das Spiel-JSON nennt die Grenze' do
    get "/api/v2/games/#{@game.id}.json"

    assert_response :success
    assert_equal 14, JSON.parse(response.body)['max_lineup_players']
  end

  private

  def add_path(side)
    "/api/v2/user/games/#{@game.id}/lineup/#{side}/add_player"
  end

  def licensed_player(last_name = 'Lang')
    create(:player, last_name:, clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                    with_licenses: [{ team: @team, status: License::APPROVED }])
  end

  def free_text_entries(count)
    Array.new(count) { |i| { 'trikot_number' => i + 1, 'player_firstname' => 'Frei', 'player_name' => "Nr#{i + 1}" } }
  end

  def entry(player, number)
    { 'player_id' => player.id, 'trikot_number' => number,
      'player_firstname' => player.first_name, 'player_name' => player.last_name }
  end

  def game_on(date, home_players: [])
    game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date:)
    Game.create!(game_day:, home_team: @team, guest_team: @opponent, start_time: '14:00',
                 forfait: 0, overtime: false, legacy: false, events: [],
                 players: { 'home' => home_players, 'guest' => [] })
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
