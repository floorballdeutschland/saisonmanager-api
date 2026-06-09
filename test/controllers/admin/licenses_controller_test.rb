require 'test_helper'

module Admin
  class LicensesControllerTest < ActionDispatch::IntegrationTest
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

      @league_go1 = create(:league, game_operation: @go1, season_id: '18')
      @team_go1   = create(:team,   league: @league_go1, club: @club1)

      @league_go2 = create(:league, game_operation: @go2, season_id: '18')
      @team_go2   = create(:team,   league: @league_go2, club: @club2)

      @league_prev = create(:league, game_operation: @go1, season_id: '17')
      @team_prev   = create(:team,   league: @league_prev, club: @club1)

      @admin = create(:user, :admin)
      @sbk   = create(:user, :sbk_scoped, game_operation_id: @go2.id)
      @vm    = create(:user, :vm, club_id: @club1.id)

      @player_go1  = create(:player, with_licenses: [{ team: @team_go1,  status: License::APPROVED, season_id: '18' }])
      @player_go2  = create(:player, with_licenses: [{ team: @team_go2,  status: License::APPROVED, season_id: '18' }])
      @player_prev = create(:player, with_licenses: [{ team: @team_prev, status: License::APPROVED, season_id: '17' }])
    end

    test 'GET as admin returns 200 with array' do
      login_as(@admin)
      get '/api/v2/admin/licenses'
      assert_response :success
      assert_kind_of Array, JSON.parse(response.body)
    end

    test 'GET with season_id filter returns licenses for that season only' do
      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '17' }
      assert_response :success
      body = JSON.parse(response.body)
      assert_kind_of Array, body
      assert_equal ['17'], body.map { |r| r['season_id'].to_s }.uniq,
                   'only previous-season licenses should be returned'
      player_ids = body.map { |r| r['player_id'] }
      assert_includes     player_ids, @player_prev.id
      assert_not_includes player_ids, @player_go1.id
      assert_not_includes player_ids, @player_go2.id
    end

    test 'GET as SBK scoped to go2 returns only go2 licenses' do
      login_as(@sbk)
      get '/api/v2/admin/licenses'
      assert_response :success
      body = JSON.parse(response.body)
      assert_kind_of Array, body
      player_ids = body.map { |r| r['player_id'] }
      assert_includes     player_ids, @player_go2.id, 'go2 player should be present'
      assert_not_includes player_ids, @player_go1.id, 'go1 player must not appear for go2-scoped SBK'
      assert_equal [@go2.id], body.map { |r| r['game_operation_id'] }.uniq
    end

    test 'GET as VM returns 403' do
      login_as(@vm)
      get '/api/v2/admin/licenses'
      assert_response :forbidden
    end

    # -------------------------------------------------------------------------
    # license_type — Erst-/Zweitlizenz-Bestimmung (#291)
    # -------------------------------------------------------------------------

    test 'Erstlizenz ist die höhere Liga – Bundesliga ("1") vor Regionalliga ("rl")' do
      buli_league = create(:league, game_operation: @go1, season_id: '18', league_class_id: '1')
      buli_team   = create(:team, league: buli_league, club: @club1)
      rl_league   = create(:league, game_operation: @go1, season_id: '18', league_class_id: 'rl')
      rl_team     = create(:team, league: rl_league, club: @club1)

      create(:player, with_licenses: [
        { team: buli_team, status: License::APPROVED, season_id: '18' },
        { team: rl_team,   status: License::APPROVED, season_id: '18' }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)

      buli_row = rows.find { |r| r['team_id'] == buli_team.id }
      rl_row   = rows.find { |r| r['team_id'] == rl_team.id }
      refute_nil buli_row, '1.-Bundesliga-Zeile muss vorhanden sein'
      refute_nil rl_row,   'Regionalliga-Zeile muss vorhanden sein'
      assert_equal 'primary',   buli_row['license_type'], '1. Bundesliga muss Erstlizenz sein'
      assert_equal 'secondary', rl_row['license_type'],   'Regionalliga (nicht-numerisch "rl") muss Zweitlizenz sein'
    end

    test 'Bei gleicher Ligastufe ist die früher genehmigte Lizenz die Erstlizenz' do
      league_a = create(:league, game_operation: @go1, season_id: '18', league_class_id: '20')
      team_a   = create(:team, league: league_a, club: @club1)
      league_b = create(:league, game_operation: @go1, season_id: '18', league_class_id: '20')
      team_b   = create(:team, league: league_b, club: @club1)

      create(:player, with_licenses: [
        { team: team_a, status: License::APPROVED, season_id: '18', created_at: 10.days.ago.iso8601 },
        { team: team_b, status: License::APPROVED, season_id: '18', created_at: 2.days.ago.iso8601 }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)

      row_a = rows.find { |r| r['team_id'] == team_a.id }
      row_b = rows.find { |r| r['team_id'] == team_b.id }
      assert_equal 'primary',   row_a['license_type'], 'früher genehmigte Lizenz ist Erstlizenz'
      assert_equal 'secondary', row_b['license_type'], 'später genehmigte Lizenz ist Zweitlizenz'
    end

    # -------------------------------------------------------------------------
    # is_zweitlizenz — echte Zweitlizenz nur bei zwei Großfeld-Lizenzen (#310)
    # -------------------------------------------------------------------------

    test 'Zwei Großfeld-Lizenzen: höhere Liga = Erstlizenz, niedrigere = Zweitlizenz' do
      gf_buli = create(:league, game_operation: @go1, season_id: '18', league_class_id: '1', field_size: 'GF')
      buli_team = create(:team, league: gf_buli, club: @club1)
      gf_rl = create(:league, game_operation: @go1, season_id: '18', league_class_id: 'rl', field_size: 'GF')
      rl_team = create(:team, league: gf_rl, club: @club1)

      create(:player, with_licenses: [
        { team: buli_team, status: License::APPROVED, season_id: '18' },
        { team: rl_team,   status: License::APPROVED, season_id: '18' }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)

      buli_row = rows.find { |r| r['team_id'] == buli_team.id }
      rl_row   = rows.find { |r| r['team_id'] == rl_team.id }

      assert_equal false, buli_row['is_zweitlizenz'], 'höhere Großfeld-Liga ist Erstlizenz, keine Zweitlizenz'
      assert_equal true,  rl_row['is_zweitlizenz'],   'niedrigere Großfeld-Liga ist Zweitlizenz'
      # Invariante: eine Zweitlizenz ist immer auch eine Zusatzlizenz (secondary).
      assert_equal 'secondary', rl_row['license_type']
    end

    test 'Kleinfeld-Zusatzlizenz ist keine Zweitlizenz' do
      gf_buli = create(:league, game_operation: @go1, season_id: '18', league_class_id: '1', field_size: 'GF')
      buli_team = create(:team, league: gf_buli, club: @club1)
      kf_league = create(:league, game_operation: @go1, season_id: '18', league_class_id: 'rl', field_size: 'KF')
      kf_team = create(:team, league: kf_league, club: @club1)

      create(:player, with_licenses: [
        { team: buli_team, status: License::APPROVED, season_id: '18' },
        { team: kf_team,   status: License::APPROVED, season_id: '18' }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)

      buli_row = rows.find { |r| r['team_id'] == buli_team.id }
      kf_row   = rows.find { |r| r['team_id'] == kf_team.id }

      assert_equal false, buli_row['is_zweitlizenz'], 'einzelne Großfeld-Lizenz ist keine Zweitlizenz'
      assert_equal false, kf_row['is_zweitlizenz'],   'Kleinfeld-Lizenz ist nie eine Zweitlizenz'
      assert_equal 'secondary', kf_row['license_type'], 'bleibt aber eine Zusatzlizenz'
    end

    test 'Zwei Großfeld-Lizenzen mit identischem Rang+Genehmigung: Invariante Zweitlizenz ⟹ secondary hält' do
      # Gleiche Ligaklasse + identischer Genehmigungszeitpunkt = vollständiger
      # Gleichstand. Ohne deterministischen Tiebreaker könnten license_type
      # (sort_by, instabil) und zweitlizenz? (min_by) unterschiedliche
      # Erstlizenzen wählen → is_zweitlizenz=true bei license_type='primary'.
      same_time = 5.days.ago.iso8601
      gf_a = create(:league, game_operation: @go1, season_id: '18', league_class_id: '20', field_size: 'GF')
      team_a = create(:team, league: gf_a, club: @club1)
      gf_b = create(:league, game_operation: @go1, season_id: '18', league_class_id: '20', field_size: 'GF')
      team_b = create(:team, league: gf_b, club: @club1)

      create(:player, with_licenses: [
        { team: team_a, status: License::APPROVED, season_id: '18', created_at: same_time },
        { team: team_b, status: License::APPROVED, season_id: '18', created_at: same_time }
      ])

      login_as(@admin)
      get '/api/v2/admin/licenses', params: { season_id: '18' }
      assert_response :success
      rows = JSON.parse(response.body)
      gf_rows = rows.select { |r| [team_a.id, team_b.id].include?(r['team_id']) }

      assert_equal 2, gf_rows.size
      # Invariante: keine Zeile darf gleichzeitig Zweitlizenz und Erstlizenz sein.
      gf_rows.each do |r|
        refute(r['is_zweitlizenz'] && r['license_type'] == 'primary',
               'Zweitlizenz muss immer secondary sein')
      end
      # Genau eine der beiden ist die Zweitlizenz.
      zweit_count = gf_rows.count { |r| r['is_zweitlizenz'] }
      assert_equal 1, zweit_count
    end
  end
end
