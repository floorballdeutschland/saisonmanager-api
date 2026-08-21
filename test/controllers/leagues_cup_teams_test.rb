require 'test_helper'

# Bestandsmannschaften in einen Pokalwettbewerb aufnehmen, ohne sie zu kopieren:
# Die Pokal-Liga wird in `teams.cup_leagues` eingetragen, die Hauptliga bleibt.
# Dieselbe Mannschaft spielt dann mit demselben Kader und denselben Lizenzen in
# beiden Wettbewerben. Der Pokal liegt dabei bewusst in einem anderen
# Spielbetrieb als die Hauptliga – das ist der Zweck der Funktion.
class LeaguesCupTeamsTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    # Bundesebene mit dem Pokal, Landesverband mit der Hauptliga der Mannschaft.
    @fd_go = create(:game_operation, :national)
    @cup = create(:league, game_operation: @fd_go, name: 'FD-Pokal')

    @lv_go = create(:game_operation)
    @lv_league = create(:league, game_operation: @lv_go, name: 'Regionalliga Ost')
    @club = create(:club)
    @team = create(:team, league: @lv_league, club: @club, name: 'Berlin Rockets')
  end

  test 'bundesweiter Admin nimmt eine Mannschaft aus fremdem Spielbetrieb in den Pokal auf' do
    login(create(:user, :admin))

    post "/api/v2/admin/leagues/#{@cup.id}/add_existing_teams", params: { team_ids: [@team.id] }

    assert_response :success
    assert_equal 1, JSON.parse(response.body)['added']
    @team.reload
    assert_includes @team.cup_leagues, @cup.id
    assert_equal @lv_league.id, @team.league_id, 'Die Hauptliga darf sich nicht ändern'
  end

  test 'SBK des Bundesverbands darf ebenfalls aufnehmen' do
    login(create(:user, :sbk_scoped, game_operation_id: @fd_go.id))

    post "/api/v2/admin/leagues/#{@cup.id}/add_existing_teams", params: { team_ids: [@team.id] }

    assert_response :success
    assert_includes @team.reload.cup_leagues, @cup.id
  end

  test 'SBK eines Landesverbands darf nicht in den fremden Pokal aufnehmen' do
    login(create(:user, :sbk_scoped, game_operation_id: @lv_go.id))

    post "/api/v2/admin/leagues/#{@cup.id}/add_existing_teams", params: { team_ids: [@team.id] }

    assert_response :forbidden
    assert_not_includes @team.reload.cup_leagues.to_a, @cup.id
  end

  test 'eine bereits aufgenommene Mannschaft wird uebersprungen und nicht doppelt eingetragen' do
    @team.update!(cup_leagues: [@cup.id])
    login(create(:user, :admin))

    post "/api/v2/admin/leagues/#{@cup.id}/add_existing_teams", params: { team_ids: [@team.id] }

    assert_response :success
    assert_equal 1, JSON.parse(response.body)['skipped']
    assert_equal [@cup.id], @team.reload.cup_leagues
  end

  test 'eine Mannschaft, deren Hauptliga der Pokal ist, wird uebersprungen' do
    own = create(:team, league: @cup, club: @club)
    login(create(:user, :admin))

    post "/api/v2/admin/leagues/#{@cup.id}/add_existing_teams", params: { team_ids: [own.id] }

    assert_response :success
    assert_equal 1, JSON.parse(response.body)['skipped']
    assert_empty own.reload.cup_leagues.to_a
  end

  test 'ohne Mannschaften antwortet der Endpoint mit 422' do
    login(create(:user, :admin))

    post "/api/v2/admin/leagues/#{@cup.id}/add_existing_teams", params: { team_ids: [] }

    assert_response :unprocessable_entity
  end

  test 'Entfernen nimmt nur den Pokal-Eintrag und loescht die Mannschaft nicht' do
    @team.update!(cup_leagues: [@cup.id])
    login(create(:user, :admin))

    assert_no_difference('Team.count') do
      delete "/api/v2/admin/leagues/#{@cup.id}/existing_teams/#{@team.id}"
    end

    assert_response :success
    @team.reload
    assert_empty @team.cup_leagues.to_a
    assert_equal @lv_league.id, @team.league_id
  end

  test 'Entfernen lehnt eine Mannschaft ab, deren Hauptliga der Wettbewerb ist' do
    own = create(:team, league: @cup, club: @club)
    login(create(:user, :admin))

    assert_no_difference('Team.count') do
      delete "/api/v2/admin/leagues/#{@cup.id}/existing_teams/#{own.id}"
    end

    assert_response :unprocessable_entity
  end

  test 'Entfernen lehnt eine Mannschaft ab, die dem Wettbewerb nicht zugeordnet ist' do
    login(create(:user, :admin))

    delete "/api/v2/admin/leagues/#{@cup.id}/existing_teams/#{@team.id}"

    assert_response :unprocessable_entity
  end

  test 'die Pokal-Liga fuehrt die aufgenommene Mannschaft in ihrer Mannschaftsliste' do
    @team.update!(cup_leagues: [@cup.id])
    login(create(:user, :admin))

    get "/api/v2/admin/leagues/#{@cup.id}/teams"

    assert_response :success
    teams = JSON.parse(response.body)['teams']
    entry = teams.find { |t| t['id'] == @team.id }
    assert_not_nil entry, 'Die aufgenommene Mannschaft fehlt in der Liste'
    assert_equal @lv_league.id, entry['league_id'], 'Die Liste muss die Hauptliga ausweisen'
    assert_equal @lv_league.name, entry['league_name']
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
