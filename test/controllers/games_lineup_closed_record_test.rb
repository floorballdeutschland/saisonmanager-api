require 'test_helper'

# Nach dem Abschluss des Spielberichts ist der Kader so gesperrt wie die
# Ereignisse: Aendern duerfen nur noch Admin und SBK des Spielbetriebs.
#
# Anlass war Spiel 61889: Das Geraet am Kampfgericht hatte den Bericht
# abgeschlossen und im Folgespiel die Kadermaske der Heimmannschaft geoeffnet.
# Beim Zurueckwechseln blieb die Maske mit der fremden Spielerliste offen, und
# ein Klick schrieb einen Spieler der anderen Mannschaft (den Schiedsrichter
# des Spiels) in den abgeschlossenen Heimkader. Die API nahm es an, weil nur
# die Ereignis-Aktionen die Sperre kannten.
class GamesLineupClosedRecordTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    @club = create(:club, game_operation: @go)
    @home_team = create(:team, league: @league, club: @club)
    @guest_team = create(:team, league: @league, club: create(:club))
    game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club,
                               number: 1, date: '2026-01-10')
    @kader_spieler = create(:player,
                            clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                            with_licenses: [{ team: @home_team, status: License::APPROVED }])
    @aufgestellt = { 'player_id' => @kader_spieler.id, 'trikot_number' => 4, 'player_name' => 'Alt',
                     'player_firstname' => 'Anna' }
    @game = Game.create!(game_day: game_day, home_team: @home_team, guest_team: @guest_team,
                         forfait: 0, overtime: false, legacy: false, events: [],
                         players: { 'home' => [@aufgestellt], 'guest' => [] },
                         home_team_coaches: { 'coach1_string' => 'Alt, Anna', 'coach1_last_name' => 'Alt',
                                              'coach1_first_name' => 'Anna' },
                         game_status: 'match_record_closed')

    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                     with_licenses: [{ team: @home_team, status: License::APPROVED }])
    @vm = create(:user, :vm, club_id: @club.id)
  end

  test 'VM kann nach dem Abschluss keinen Spieler mehr aufstellen' do
    login(@vm)

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 }

    assert_response :forbidden
    assert_equal([@kader_spieler.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'VM kann nach dem Abschluss keinen Spieler mehr herausnehmen' do
    login(@vm)

    post "/api/v2/user/games/#{@game.id}/lineup/home/remove_player", params: { trikot_number: 4 }, as: :json

    assert_response :forbidden
    assert_equal([@kader_spieler.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  # Einzeln statt in einem Sammeltest, damit ein Fehlschlag die Aktion nennt.
  # Starting Six und Auszeichnung nehmen den bereits aufgestellten Spieler
  # (:kader), damit nur die Sperre die Anfrage abweisen kann.
  {
    'set_captain' => ['lineup/home/set_captain', { trikot_number: 4 }],
    'add_coach' => ['lineup/home/add_coach/2', { first_name: 'Carla', last_name: 'Coach' }],
    'remove_coach' => ['lineup/home/remove_coach/1', {}],
    'set_starting_player' => ['starting/home/goalkeeper/set_player', { player_id: :kader }],
    'set_player_award' => ['award/home/mvp/set_player', { player_id: :kader }]
  }.each do |action, (path, params)|
    test "VM kann nach dem Abschluss #{action} nicht mehr ausfuehren" do
      login(@vm)
      vorher = @game.reload.attributes.slice('players', 'home_team_coaches', 'starting_players', 'awards')

      params = params.transform_values { |v| v == :kader ? @kader_spieler.id : v }
      post "/api/v2/user/games/#{@game.id}/#{path}", params: params, as: :json

      assert_response :forbidden
      assert_equal vorher, @game.reload.attributes.slice('players', 'home_team_coaches', 'starting_players', 'awards')
    end
  end

  test 'die Sperre gilt auch fuer den Status finalized' do
    @game.update!(game_status: 'finalized')
    login(@vm)

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 }

    assert_response :forbidden
    assert_equal([@kader_spieler.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  # Das Geraet am Kampfgericht arbeitet mit dem Sekretariats-Link, ohne Login.
  # Genau von dort kam der Eintrag im Spiel 61889. Dreht jemand in
  # can_edit_lineup_of? die Reihenfolge um (Token zuerst, wie in
  # can_edit_game?), oeffnet sich die Luecke wieder.
  test 'der Sekretariats-Link kann den abgeschlossenen Kader nicht aendern' do
    token = secretary_token

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 },
         headers: { 'X-Api-Key' => API_KEY, 'X-Secretary-Token' => token }

    assert_response :forbidden
    assert_equal([@kader_spieler.id], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'der Sekretariats-Link stellt vor dem Abschluss weiter auf' do
    @game.update!(game_status: 'aftergame')
    token = secretary_token

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 },
         headers: { 'X-Api-Key' => API_KEY, 'X-Secretary-Token' => token }

    assert_response :success
    assert_includes @game.reload.players['home'].map { |p| p['player_id'] }, @player.id
  end

  test 'die SBK des Spielbetriebs darf den abgeschlossenen Kader berichtigen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/lineup/home/remove_player", params: { trikot_number: 4 }, as: :json

    assert_response :success
    assert_empty @game.reload.players['home']
  end

  # Der haeufigste Berichtigungsweg: die SBK traegt einen vergessenen Spieler
  # nach. Laeuft zugleich durch die Lizenzpruefung.
  test 'die SBK des Spielbetriebs darf im abgeschlossenen Bericht nachtragen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 }

    assert_response :success
    assert_includes @game.reload.players['home'].map { |p| p['player_id'] }, @player.id
  end

  # Gleiche Grenze wie bei add_event (#214): Eine SBK-Rolle in einem anderen
  # Verband hebelt die Sperre nicht aus, auch nicht zusammen mit einer
  # passenden VM-Rolle.
  test 'eine fachfremde SBK-Rolle hebelt die Sperre nicht aus' do
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    user = create(:user, :sbk_scoped, game_operation_id: other_go.id)
    user.update!(permissions: user.permissions + [{ 'user_group_id' => 4, 'club_id' => @club.id }])
    login(user)

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 }

    assert_response :forbidden
  end

  test 'vor dem Abschluss stellt der VM weiter auf' do
    @game.update!(game_status: 'aftergame')
    login(@vm)

    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 }

    assert_response :success
    assert_includes @game.reload.players['home'].map { |p| p['player_id'] }, @player.id
  end

  def secretary_token
    _link, token = GameDaySecretaryLink.generate!(game_days: [@game.game_day], created_by: create(:user, :admin))
    token
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
