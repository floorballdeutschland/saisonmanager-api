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
    @aufgestellt = { 'player_id' => 1, 'trikot_number' => 4, 'player_name' => 'Alt',
                     'player_firstname' => 'Anna' }
    @game = Game.create!(game_day: game_day, home_team: @home_team, guest_team: @guest_team,
                         forfait: 0, overtime: false, legacy: false, events: [],
                         players: { 'home' => [@aufgestellt], 'guest' => [] },
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
    assert_equal([1], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'VM kann nach dem Abschluss keinen Spieler mehr herausnehmen' do
    login(@vm)

    post "/api/v2/user/games/#{@game.id}/lineup/home/remove_player", params: { trikot_number: 4 }, as: :json

    assert_response :forbidden
    assert_equal([1], @game.reload.players['home'].map { |p| p['player_id'] })
  end

  test 'VM kann nach dem Abschluss Kapitaen, Betreuer, Starting Six und Auszeichnungen nicht mehr setzen' do
    login(@vm)
    base = "/api/v2/user/games/#{@game.id}"

    post "#{base}/lineup/home/set_captain", params: { trikot_number: 4 }
    assert_response :forbidden
    post "#{base}/lineup/home/add_coach/1", params: { first_name: 'Carla', last_name: 'Coach' }
    assert_response :forbidden
    post "#{base}/lineup/home/remove_coach/1"
    assert_response :forbidden
    post "#{base}/starting/home/goalkeeper/set_player", params: { player_id: @player.id }
    assert_response :forbidden
    post "#{base}/award/home/mvp/set_player", params: { player_id: @player.id }
    assert_response :forbidden

    @game.reload
    assert_not @game.players['home'].first['captain']
    assert_empty @game.home_team_coaches.to_h
    assert_empty @game.starting_players.to_h
    assert_empty @game.awards.to_h
  end

  test 'die SBK des Spielbetriebs darf den abgeschlossenen Kader berichtigen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/games/#{@game.id}/lineup/home/remove_player", params: { trikot_number: 4 }, as: :json

    assert_response :success
    assert_empty @game.reload.players['home']
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

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
