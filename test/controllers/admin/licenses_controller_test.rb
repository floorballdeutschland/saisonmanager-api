require 'test_helper'

class Admin::LicensesControllerTest < ActionDispatch::IntegrationTest
  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  setup do
    @setting = create(:setting, current_season_id: '18')

    # GOs müssen eine state_association haben – sonst löst sich das SBK-Permission
    # auf [0] (global) auf, weil GOs ohne state_association als national gelten.
    @sa1 = create(:state_association)
    @sa2 = create(:state_association)
    @go1 = GameOperation.create!(name: "GO1 #{SecureRandom.hex(4)}", short_name: "G1#{SecureRandom.hex(2)}",
                                 state_association: @sa1)
    @go2 = GameOperation.create!(name: "GO2 #{SecureRandom.hex(4)}", short_name: "G2#{SecureRandom.hex(2)}",
                                 state_association: @sa2)

    @club1 = create(:club)
    @club2 = create(:club)

    # League in go1, current season
    @league_go1 = create(:league, game_operation: @go1, season_id: '18')
    @team_go1   = create(:team,   league: @league_go1, club: @club1)

    # League in go2, current season
    @league_go2 = create(:league, game_operation: @go2, season_id: '18')
    @team_go2   = create(:team,   league: @league_go2, club: @club2)

    # League in go1, previous season
    @league_prev = create(:league, game_operation: @go1, season_id: '17')
    @team_prev   = create(:team,   league: @league_prev, club: @club1)

    @admin = create(:user, :admin)
    @sbk   = create(:user, :sbk_scoped, game_operation_id: @go2.id)
    @vm    = create(:user, :vm, club_id: @club1.id)

    # Player licensed to go1 team, current season
    @player_go1 = create(:player, with_licenses: [{ team: @team_go1, status: License::APPROVED, season_id: '18' }])

    # Player licensed to go2 team, current season
    @player_go2 = create(:player, with_licenses: [{ team: @team_go2, status: License::APPROVED, season_id: '18' }])

    # Player licensed to go1 team, previous season
    @player_prev = create(:player, with_licenses: [{ team: @team_prev, status: License::APPROVED, season_id: '17' }])
  end

  # 1. Admin sees 200 with an array
  test 'GET as admin returns 200 with array' do
    login_as(@admin)
    get '/api/v2/admin/licenses'
    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body
  end

  # 2. season_id filter scopes results to that season
  test 'GET with season_id filter returns licenses for that season only' do
    login_as(@admin)

    get '/api/v2/admin/licenses', params: { season_id: '17' }
    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body

    returned_season_ids = body.map { |r| r['season_id'].to_s }.uniq
    assert_equal ['17'], returned_season_ids, 'only previous-season licenses should be returned'

    player_ids = body.map { |r| r['player_id'] }
    assert_includes player_ids, @player_prev.id
    assert_not_includes player_ids, @player_go1.id
    assert_not_includes player_ids, @player_go2.id
  end

  # 3. SBK scoped to go2 only sees go2 licenses; go1 license absent
  test 'GET as SBK scoped to go2 returns only go2 licenses' do
    login_as(@sbk)

    get '/api/v2/admin/licenses'
    assert_response :success
    body = JSON.parse(response.body)
    assert_kind_of Array, body

    player_ids = body.map { |r| r['player_id'] }
    assert_includes     player_ids, @player_go2.id, 'go2 player should be present'
    assert_not_includes player_ids, @player_go1.id, 'go1 player must not appear for go2-scoped SBK'

    game_op_ids = body.map { |r| r['game_operation_id'] }.uniq
    assert_equal [@go2.id], game_op_ids
  end

  # 4. VM gets 403
  test 'GET as VM returns 403' do
    login_as(@vm)
    get '/api/v2/admin/licenses'
    assert_response :forbidden
  end
end
