require 'test_helper'

# Turnierspieltag im Nachwuchs: Am Tisch sitzt der ausrichtende Verein, und das
# ist oft ein Teammanager. Angemeldet sah er bisher nur die Spiele seiner
# eigenen Mannschaft -- fuer die uebrigen musste er sich erst selbst einen
# Sekretariatslink ausstellen und sich damit abgemeldet wieder anmelden. Fuer
# den Vereinsmanager des Ausrichters galt das Recht laengst.
class GamesHostingTeamManagerTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @ausrichter = create(:club, state_association_id: @sa.id)
    @gastverein = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @ausrichter,
                                number: 1, date: '2026-01-10')

    @eigenes_team = create(:team, league: @league, club: @ausrichter)
    # Ein Spiel des Turniers ohne eigene Beteiligung: zwei fremde Mannschaften.
    @fremdes_spiel = Game.create!(
      game_day: @game_day,
      home_team: create(:team, league: @league, club: create(:club)),
      guest_team: create(:team, league: @league, club: create(:club)),
      forfait: 0, overtime: false, legacy: false,
      events: [], players: { 'home' => [], 'guest' => [] }
    )

    @tm_ausrichter = create(:user, :tm, team_id: @eigenes_team.id)
    @tm_gast = create(:user, :tm, team_id: create(:team, league: @league, club: @gastverein).id)
  end

  test 'der TM des Ausrichters darf den Bericht eines fremden Spiels fuehren' do
    login(@tm_ausrichter)

    get "/api/v2/games/#{@fremdes_spiel.id}.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_includes JSON.parse(response.body)['permission'], 'edit_game_report'
  end

  test 'der TM des Ausrichters sieht die internen Felder des fremden Spiels' do
    @fremdes_spiel.update!(special_event_string: 'Interner Vermerk')
    login(@tm_ausrichter)

    get "/api/v2/user/games/#{@fremdes_spiel.id}/additional_fields.json",
        headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal 'Interner Vermerk', JSON.parse(response.body)['special_event_string']
  end

  test 'der TM eines Gastvereins bleibt bei den eigenen Spielen' do
    @fremdes_spiel.update!(special_event_string: 'Interner Vermerk')
    login(@tm_gast)

    get "/api/v2/games/#{@fremdes_spiel.id}.json", headers: { 'X-Api-Key' => API_KEY }
    assert_response :success
    assert_not_includes JSON.parse(response.body)['permission'], 'edit_game_report'

    get "/api/v2/user/games/#{@fremdes_spiel.id}/additional_fields.json",
        headers: { 'X-Api-Key' => API_KEY }
    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
