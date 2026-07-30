require 'test_helper'

# DELETE /api/v2/admin/leagues/:id – Löschen einer Liga.
#
# Kernaussage der Tests: echte Historie (angepfiffene Spiele, Lizenzen, Sperren,
# Feedback, Verweise anderer Ligen) blockiert die Löschung, ein rein
# ungespielter Spielplan und leere Teams werden mit abgeräumt.
class LeagueDeleteTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
  end

  test 'Admin löscht eine leere Liga' do
    login(create(:user, :admin))

    assert_difference('League.count', -1) do
      delete "/api/v2/admin/leagues/#{@league.id}"
    end

    assert_response :no_content
  end

  test 'SBK des Spielbetriebs darf löschen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    assert_difference('League.count', -1) do
      delete "/api/v2/admin/leagues/#{@league.id}"
    end

    assert_response :no_content
  end

  test 'SBK eines fremden Spielbetriebs darf nicht löschen' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :forbidden
    assert League.exists?(@league.id)
  end

  test 'VM darf nicht löschen' do
    login(create(:user, :vm, club_id: @club.id))

    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :forbidden
    assert League.exists?(@league.id)
  end

  test 'ohne Login ergibt 401' do
    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :unauthorized
    assert League.exists?(@league.id)
  end

  # Der Endpunkt steht bewusst in der except-Liste von authenticate_public_request,
  # ein Frontend-API-Key darf hier also gerade NICHT durchkommen.
  test 'ein reiner API-Key genügt nicht' do
    raw_key, = ApiKey.generate(name: 'Frontend-Test')

    delete "/api/v2/admin/leagues/#{@league.id}", headers: { 'X-Api-Key' => raw_key }

    assert_response :unauthorized
    assert League.exists?(@league.id)
  end

  test 'ungespielter Spielplan und leere Teams werden mit abgeräumt' do
    login(create(:user, :admin))
    home = create(:team, league: @league, club: @club)
    guest = create(:team, league: @league, club: @club)
    game_day = create(:game_day, league: @league, club: @club)
    create(:game, game_day:, home_team: home, guest_team: guest)

    assert_difference(
      { 'League.count' => -1, 'GameDay.count' => -1, 'Team.count' => -2, 'Game.count' => -1 }
    ) do
      delete "/api/v2/admin/leagues/#{@league.id}"
    end

    assert_response :no_content
  end

  test 'angepfiffenes Spiel blockiert die Löschung' do
    login(create(:user, :admin))
    home = create(:team, league: @league, club: @club)
    guest = create(:team, league: @league, club: @club)
    game_day = create(:game_day, league: @league, club: @club)
    create(:game, :with_result, game_day:, home_team: home, guest_team: guest)

    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :unprocessable_entity
    assert_match(/Spiele/, JSON.parse(response.body)['message'])
    assert League.exists?(@league.id)
  end

  test 'zugeordnete Lizenzen blockieren die Löschung' do
    login(create(:user, :admin))
    team = create(:team, league: @league, club: @club)
    create(:player, with_licenses: [{ team: }])

    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :unprocessable_entity
    assert_match(/Lizenzen/, JSON.parse(response.body)['message'])
    assert League.exists?(@league.id)
  end

  test 'Verweis einer anderen Liga blockiert die Löschung' do
    login(create(:user, :admin))
    create(:league, game_operation: @go, league_id_preround: @league.id)

    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :unprocessable_entity
    assert_match(/Vorrunde/, JSON.parse(response.body)['message'])
    assert League.exists?(@league.id)
  end

  test 'Qualifikation einer anderen Liga in diese Liga blockiert die Löschung' do
    login(create(:user, :admin))
    source = create(:league, game_operation: @go)
    LeagueQualification.create!(
      source_league_id: source.id,
      target_league_id: @league.id,
      rank_from: 1,
      rank_to: 1,
      qualification_type: 'promotion'
    )

    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :unprocessable_entity
    assert_match(/qualifizieren/, JSON.parse(response.body)['message'])
    assert League.exists?(@league.id)
  end

  test 'Team einer anderen Liga mit dieser Liga als Zusatzliga blockiert die Löschung' do
    login(create(:user, :admin))
    other_league = create(:league, game_operation: @go)
    create(:team, league: other_league, club: @club, cup_leagues: [@league.id])

    delete "/api/v2/admin/leagues/#{@league.id}"

    assert_response :unprocessable_entity
    assert_match(/zusätzliche Liga/, JSON.parse(response.body)['message'])
    assert League.exists?(@league.id)
  end

  test 'eigene Qualifikationen der Liga werden mit gelöscht' do
    login(create(:user, :admin))
    target = create(:league, game_operation: @go)
    LeagueQualification.create!(
      source_league_id: @league.id,
      target_league_id: target.id,
      rank_from: 1,
      rank_to: 1,
      qualification_type: 'promotion'
    )

    assert_difference('LeagueQualification.count', -1) do
      delete "/api/v2/admin/leagues/#{@league.id}"
    end

    assert_response :no_content
  end
end
