require 'test_helper'

# Aufstellung aus dem letzten Spiel der Mannschaft übernehmen (feedback#69).
# Quelle ist das jüngste frühere Spiel derselben Mannschaft in derselben Saison
# mit Aufstellung auf ihrer Seite. Je Person gelten die Regeln von
# add_player_to_lineup, nur gesammelt statt einzeln abgewiesen.
class GamesLineupCopyFromLastGameTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league')
    @club = create(:club, game_operation: @go)
    @team = create(:team, league: @league, club: @club)
    @opponent = create(:team, league: @league, club: create(:club))

    @anna = licensed_player('Anna', 'Alt')
    @berta = licensed_player('Berta', 'Brandt')
    @carla = licensed_player('Carla', 'Conrad')

    @game = game_on('2026-01-17', '14:00', home: @team, guest: @opponent)

    login(create(:user, :admin))
  end

  test 'übernimmt Personen, Nummern und Torwart aus dem jüngsten früheren Spiel, nicht den Kapitän' do
    game_on('2026-01-03', '12:00', home: @team, guest: @opponent,
                                   home_players: [entry(@carla, 99)])
    source = game_on('2026-01-10', '12:00', home: @team, guest: @opponent,
                                            home_players: [entry(@anna, 4, captain: true), entry(@berta, 1, goalkeeper: true)])

    post copy_path('home')

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body['added_count']
    assert_equal source.id, body['source_game']['id']
    assert_empty body['skipped']

    home = @game.reload.players['home']
    assert_equal([[@anna.id, 4], [@berta.id, 1]], home.map { |p| [p['player_id'], p['trikot_number']] })
    assert_equal([nil, true], home.map { |p| p['goalkeeper'] })
    assert(home.none? { |p| p['captain'] })
    assert_equal 'Alt', home.first['player_name']
  end

  test 'Spiele nach dem Zielspiel und aus einer anderen Saison zählen nicht' do
    earlier = game_on('2026-01-10', '12:00', home: @team, guest: @opponent, home_players: [entry(@anna, 4)])
    game_on('2026-01-17', '18:00', home: @team, guest: @opponent, home_players: [entry(@berta, 5)])
    old_league = create(:league, :previous_season, game_operation: @go)
    game_on('2026-01-16', '12:00', home: @team, guest: @opponent, home_players: [entry(@carla, 6)],
                                   league: old_league)

    post copy_path('home')

    assert_response :success
    assert_equal earlier.id, JSON.parse(response.body)['source_game']['id']
    assert_equal([@anna.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'nimmt die Seite der Mannschaft im Quellspiel, auch wenn sie dort Gast war' do
    game_on('2026-01-10', '12:00', home: @opponent, guest: @team,
                                   home_players: [entry(@carla, 9)], guest_players: [entry(@anna, 4)])

    post copy_path('home')

    assert_response :success
    assert_equal([@anna.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'überspringt Personen ohne Lizenz für die Mannschaft und Freitext-Einträge' do
    unlicensed = create(:player, first_name: 'Dora', last_name: 'Dahl',
                                 clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    game_on('2026-01-10', '12:00', home: @team, guest: @opponent,
                                   home_players: [entry(@anna, 4), entry(unlicensed, 8),
                                                  { 'trikot_number' => 12, 'player_firstname' => 'Frei',
                                                    'player_name' => 'Text' }])

    post copy_path('home')

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body['added_count']
    assert_equal([[8, 'kein Lizenzantrag für diese Mannschaft'], [12, 'kein Spielerprofil']],
                 body['skipped'].map { |s| [s['trikot_number'], s['reason']] })
    assert_equal([@anna.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'lässt vorhandene Einträge und vergebene Nummern stehen' do
    @game.update!(players: { 'home' => [entry(@anna, 4)], 'guest' => [] })
    game_on('2026-01-10', '12:00', home: @team, guest: @opponent,
                                   home_players: [entry(@anna, 10), entry(@berta, 4), entry(@carla, 7)])

    post copy_path('home')

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal(['bereits aufgestellt', 'Nummer 4 bereits vergeben'], body['skipped'].map { |s| s['reason'] })
    assert_equal([[@anna.id, 4], [@carla.id, 7]],
                 @game.reload.players['home'].map { |p| [p['player_id'], p['trikot_number']] })
  end

  test 'erkennt eine schon aufgestellte Person auch, wenn ihre ID als Text abgelegt ist' do
    @game.update!(players: { 'home' => [entry(@anna, 4).merge('player_id' => @anna.id.to_s)], 'guest' => [] })
    game_on('2026-01-10', '12:00', home: @team, guest: @opponent, home_players: [entry(@anna, 10)])

    post copy_path('home')

    assert_response :success
    assert_equal(['bereits aufgestellt'], JSON.parse(response.body)['skipped'].map { |s| s['reason'] })
    assert_equal 1, @game.reload.players['home'].size
  end

  # Die Kadermaske listet nur aktive Vereinsmitglieder ohne erloschene
  # Transfer-Lizenz (ClubsController#user_team_licenses). Wer sonst übernommen
  # würde, stünde in der Aufstellung, ohne dass die Maske eine Zeile zum
  # Austragen zeigt.
  test 'übernimmt niemanden, den die Kadermaske nicht zum Austragen anbietet' do
    transferred = create(:player, first_name: 'Erna', last_name: 'Eck',
                                  clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                                  with_licenses: [{ team: @team, status: License::TRANSFER }])
    left = create(:player, first_name: 'Frida', last_name: 'Fuchs',
                           clubs: [{ 'club_id' => @club.id, 'valid_until' => '2025-12-31' }],
                           with_licenses: [{ team: @team, status: License::APPROVED }])
    deactivated = licensed_player('Gerda', 'Gans')
    deactivated.update_columns(deactivated_at: Time.current)
    game_on('2026-01-10', '12:00', home: @team, guest: @opponent,
                                   home_players: [entry(@anna, 4), entry(transferred, 5), entry(left, 6),
                                                  entry(deactivated, 7)])

    post copy_path('home')

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal([[5, 'Lizenz durch Transfer erloschen'], [6, 'nicht mehr Mitglied im Verein der Mannschaft'],
                  [7, 'Profil deaktiviert']],
                 body['skipped'].map { |s| [s['trikot_number'], s['reason']] })
    assert_equal([@anna.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'ohne früheres Spiel mit Aufstellung kommt eine leere Übernahme zurück' do
    game_on('2026-01-10', '12:00', home: @team, guest: @opponent)

    post copy_path('home')

    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body['source_game']
    assert_equal 0, body['added_count']
    assert_empty @game.reload.players['home']
  end

  test 'lehnt eine unbekannte Seite ab' do
    post copy_path('referee')

    assert_response :unprocessable_entity
  end

  test 'nach dem Abschluss darf ein VM nicht mehr übernehmen' do
    game_on('2026-01-10', '12:00', home: @team, guest: @opponent, home_players: [entry(@anna, 4)])
    @game.update!(game_status: 'match_record_closed')
    reset!
    login(create(:user, :vm, club_id: @club.id))

    post copy_path('home')

    assert_response :forbidden
    assert_empty @game.reload.players['home']
  end

  private

  def copy_path(side)
    "/api/v2/user/games/#{@game.id}/lineup/#{side}/copy_from_last_game"
  end

  def licensed_player(first_name, last_name)
    create(:player, first_name:, last_name:,
                    clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                    with_licenses: [{ team: @team, status: License::APPROVED }])
  end

  def entry(player, number, captain: false, goalkeeper: false)
    item = { 'player_id' => player.id, 'trikot_number' => number,
             'player_firstname' => player.first_name, 'player_name' => player.last_name }
    item['captain'] = true if captain
    item['goalkeeper'] = true if goalkeeper
    item
  end

  def game_on(date, time, home:, guest:, home_players: [], guest_players: [], league: @league)
    game_day = GameDay.create!(league:, arena: create(:arena), club: @club, number: 1, date:)
    Game.create!(game_day:, home_team: home, guest_team: guest, start_time: time,
                 forfait: 0, overtime: false, legacy: false, events: [],
                 players: { 'home' => home_players, 'guest' => guest_players })
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
