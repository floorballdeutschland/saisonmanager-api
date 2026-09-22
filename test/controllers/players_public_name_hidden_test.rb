require 'test_helper'

# Die Schalter der Spielerverwaltung und die Grenze, an der die Maskierung
# endet: In der Verwaltung steht weiter der echte Name, in der oeffentlichen
# Ausgabe der Platzhalter.
class PlayersPublicNameHiddenTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze # test/fixtures/api_keys.yml
  PLACEHOLDER = PublicPlayerNames::HIDDEN_LAST_NAME

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @player = create(:player, first_name: 'Pierre', last_name: 'Beispiel')
    @game = Game.create!(
      game_day: @game_day, home_team: @home, guest_team: @guest,
      started: true, ended: true, forfait: 0, overtime: false, legacy: false,
      events: [],
      players: { 'home' => [{ 'player_id' => @player.id, 'player_firstname' => 'Pierre',
                              'player_name' => 'Beispiel', 'trikot_number' => '7' }],
                 'guest' => [] }
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  test 'die Verbandsverwaltung schaltet die Anonymisierung und nimmt sie zurueck' do
    login(create(:user, :admin))

    post "/api/v2/admin/players/#{@player.id}/hide_public_name", params: { reason: 'DSGVO 2026-09-22' }
    assert_response :success
    assert_not_nil response.parsed_body['public_name_hidden_at']
    assert @player.reload.public_name_hidden?
    # In der Verwaltung bleibt der echte Name stehen.
    assert_equal 'Beispiel', response.parsed_body['last_name']

    post "/api/v2/admin/players/#{@player.id}/show_public_name"
    assert_response :success
    assert_nil response.parsed_body['public_name_hidden_at']
    assert_not @player.reload.public_name_hidden?
  end

  test 'die SBK darf nicht anonymisieren' do
    login(create(:user, :sbk_global))

    post "/api/v2/admin/players/#{@player.id}/hide_public_name"

    assert_response :forbidden
    assert_not @player.reload.public_name_hidden?
  end

  test 'ohne Anmeldung ist der Schalter nicht erreichbar' do
    post "/api/v2/admin/players/#{@player.id}/hide_public_name", headers: { 'X-Api-Key' => API_KEY }

    assert_response :unauthorized
    assert_not @player.reload.public_name_hidden?
  end

  test 'ein zweites Anonymisieren wird abgewiesen' do
    login(create(:user, :admin))
    post "/api/v2/admin/players/#{@player.id}/hide_public_name"
    assert_response :success

    post "/api/v2/admin/players/#{@player.id}/hide_public_name"
    assert_response :unprocessable_entity
  end

  test 'ein zu langer Vermerk wird abgewiesen statt abgeschnitten' do
    login(create(:user, :admin))

    post "/api/v2/admin/players/#{@player.id}/hide_public_name", params: { reason: 'x' * 256 }

    assert_response :unprocessable_entity
    assert_not @player.reload.public_name_hidden?
  end

  test 'die oeffentliche Spielseite nennt den Platzhalter' do
    @player.hide_public_name!(create(:user, :admin).id)

    get "/api/v2/games/#{@game.id}.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_not_includes response.body, 'Beispiel'
    assert_not_includes response.body, 'Pierre'
    assert_includes response.body, PLACEHOLDER
  end

  test 'die oeffentliche Spielerstatistik nennt den Platzhalter' do
    @player.hide_public_name!(create(:user, :admin).id)

    get "/api/v2/players/#{@player.id}/stats", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal PLACEHOLDER, response.parsed_body['player']['last_name']
    assert_equal '', response.parsed_body['player']['first_name']
  end

  # Die Mannschafts-Scorerliste ist die einzige der maskierten Stellen, die den
  # Namen aus dem Spielerdatensatz liest statt aus dem Spielbericht. Die
  # bestehenden Tests dieses Endpunkts pruefen nur Laengen und Zahlen, eine
  # entfernte Maskierung fiele dort also nicht auf.
  test 'die oeffentliche Mannschaftsstatistik nennt den Platzhalter' do
    league = create(:league, game_operation: @go, enable_scorer: true)
    team = create(:team, league: league, club: @club)
    guest = create(:team, league: league, club: @club)
    game_day = GameDay.create!(league: league, arena: @arena, club: @club, number: 1, date: '2026-01-01')
    Game.create!(
      game_day: game_day, home_team: team, guest_team: guest,
      started: true, ended: true, forfait: 0, overtime: false, legacy: false,
      events: [{ 'id' => 1, 'period' => 1, 'time' => '5:00', 'home_number' => '7',
                 'home_goals' => 1, 'guest_goals' => 0 }],
      players: { 'home' => [{ 'trikot_number' => '7', 'player_id' => @player.id }], 'guest' => [] }
    )
    @player.hide_public_name!(create(:user, :admin).id)

    get "/api/v2/teams/#{team.id}/stats", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_not_includes response.body, 'Beispiel'
    assert_equal PLACEHOLDER, response.parsed_body['scorer'].first['last_name']
    assert_equal '', response.parsed_body['scorer'].first['first_name']
  end

  # Die oeffentliche Transferliste zieht den Namen aus dem Spielerdatensatz,
  # nicht aus dem Spielbericht, und faellt deshalb leicht durch die Durchsicht.
  # Betroffen ist, wer mitten in der Saison aufhoert.
  test 'die oeffentliche Transferliste nennt den Platzhalter' do
    Transfer.create!(player_id: @player.id, former_club_id: @club.id, new_club_id: @club.id,
                     season_id: Setting.current_season_id)
    @player.hide_public_name!(create(:user, :admin).id)

    get '/api/v2/transfers/public', headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_not_includes response.body, 'Beispiel'
    assert_not_includes response.body, 'Pierre'
    entry = response.parsed_body.first
    assert_equal PLACEHOLDER, entry['player_last_name']
    assert_equal PLACEHOLDER, entry['player_name']
  end

  # Der Cache dieser Liste steht 30 Minuten und haelt bereits aufgeloeste Namen.
  # Ohne das Leeren beim Umschalten bliebe der Klarname so lange stehen.
  test 'der Cache der Transferliste wird beim Umschalten geleert' do
    Transfer.create!(player_id: @player.id, former_club_id: @club.id, new_club_id: @club.id,
                     season_id: Setting.current_season_id)

    with_real_cache do
      get '/api/v2/transfers/public', headers: { 'X-Api-Key' => API_KEY }
      assert_includes response.body, 'Beispiel'

      @player.hide_public_name!(create(:user, :admin).id)

      get '/api/v2/transfers/public', headers: { 'X-Api-Key' => API_KEY }
      assert_not_includes response.body, 'Beispiel'
    end
  end

  # Die Maske uebernimmt die Antwort auf das Deaktivieren ungefiltert, und die
  # Pruefung auf den Anonymisierungs-Schalter hat bewusst keinen Rueckfall auf
  # ein Rollen-Flag. Fehlt das Feld hier, verschwindet der ganze Abschnitt aus
  # dem geoeffneten Profil.
  test 'die Antwort auf das Deaktivieren traegt can_hide_public_name mit' do
    login(create(:user, :admin))

    post "/api/v2/admin/players/#{@player.id}/deactivate", params: { reason: 'Karriereende' }

    assert_response :success
    assert response.parsed_body['can_hide_public_name']
  end

  test 'die Spielerverwaltung zeigt den echten Namen weiter' do
    @player.hide_public_name!(create(:user, :admin).id)
    login(create(:user, :admin))

    get "/api/v2/admin/players/#{@player.id}"

    assert_response :success
    assert_equal 'Beispiel', response.parsed_body['last_name']
    assert_equal 'Pierre', response.parsed_body['first_name']
    assert response.parsed_body['can_hide_public_name']
    assert_not_nil response.parsed_body['public_name_hidden_at']
  end
end
