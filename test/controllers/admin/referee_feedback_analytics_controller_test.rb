require 'test_helper'

module Admin
  class RefereeFeedbackAnalyticsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      # FD ist national (kein state_association_id) → rsk/ansetzer kollabieren auf
      # den globalen Scope 0 und dürfen das Feedback sehen.
      @fd = create(:game_operation, state_association_id: nil)
      @lv_sa = create(:state_association)
      @lv_go = create(:game_operation, state_association_id: @lv_sa.id)
      @league = create(:league, season_id: '18')
    end

    test 'nur Admin/FD sieht die Auswertung, LV-RSK ist gesperrt' do
      login(create(:user, :rsk_scoped, game_operation_id: @lv_go.id))
      get '/api/v2/admin/referee_feedback_analytics'
      assert_response :forbidden
    end

    test 'FD-RSK darf die Auswertung sehen' do
      login(create(:user, :rsk_scoped, game_operation_id: @fd.id))
      get '/api/v2/admin/referee_feedback_analytics'
      assert_response :success
    end

    test 'Mittelwerte nur über sichtbare Rückmeldungen; Gespann zählt bei beiden Schiris' do
      r1 = create(:referee)
      r2 = create(:referee)
      create(:referee_feedback, game: game_in(@league), team: create(:team, league: @league),
                                referee1_id: r1.id, referee2_id: r2.id, line_rating: 8, communication_rating: 6)
      # Ausgeblendete Rückmeldung darf die Kennzahlen nicht verändern.
      create(:referee_feedback, game: game_in(@league), team: create(:team, league: @league),
                                referee1_id: r1.id, line_rating: 2, communication_rating: 2, status: 'hidden')

      login(@admin)
      get '/api/v2/admin/referee_feedback_analytics'

      assert_response :success
      body = response.parsed_body
      assert_equal 1, body['overall']['count']
      assert_equal 8.0, body['overall']['avg_line_rating']
      assert_equal 6.0, body['overall']['avg_communication_rating']
      # Ein Gespann-Feedback erzeugt je einen Datenpunkt für r1 und r2.
      assert_equal 2, body['referees'].size
      assert(body['referees'].all? { |r| r['count'] == 1 })
    end

    test 'min_count markiert Schiris unterhalb der Schwelle als nicht rankbar' do
      r1 = create(:referee)
      create(:referee_feedback, game: game_in(@league), team: create(:team, league: @league),
                                referee1_id: r1.id, line_rating: 7, communication_rating: 7)

      login(@admin)
      get '/api/v2/admin/referee_feedback_analytics', params: { min_count: 3 }

      assert_response :success
      entry = response.parsed_body['referees'].find { |r| r['referee_id'] == r1.id }
      assert_equal 1, entry['count']
      assert_equal false, entry['ranked']
    end

    test 'Top-Gruppe per Tag: Gruppen-Kennzahlen und in_group-Markierung' do
      r1 = create(:referee)
      r2 = create(:referee)
      tag = RefereeTag.create!(name: 'Kader', game_operation_id: nil)
      RefereeTagging.create!(referee: r1, referee_tag: tag)
      create(:referee_feedback, game: game_in(@league), team: create(:team, league: @league),
                                referee1_id: r1.id, referee2_id: r2.id, line_rating: 9, communication_rating: 9)

      login(@admin)
      get '/api/v2/admin/referee_feedback_analytics', params: { tag_id: tag.id }

      assert_response :success
      body = response.parsed_body
      assert_equal tag.id, body['group']['tag_id']
      assert_equal 1, body['group']['count']
      assert(body['referees'].find { |r| r['referee_id'] == r1.id }['in_group'])
      assert_not(body['referees'].find { |r| r['referee_id'] == r2.id }['in_group'])
    end

    test 'result-Filter splittet nach Ausgang des bewertenden Teams' do
      r1 = create(:referee)
      home = create(:team, league: @league)
      guest = create(:team, league: @league)
      game = game_in(@league, home_team: home, guest_team: guest, home_goals: 5, guest_goals: 2)
      create(:referee_feedback, game: game, team: home, referee1_id: r1.id)
      create(:referee_feedback, game: game, team: guest, referee1_id: r1.id)

      login(@admin)
      get '/api/v2/admin/referee_feedback_analytics', params: { result: 'won' }

      assert_response :success
      assert_equal 1, response.parsed_body['overall']['count']
    end

    test 'CSV-Export liefert die Schiri-Tabelle' do
      r1 = create(:referee)
      create(:referee_feedback, game: game_in(@league), team: create(:team, league: @league),
                                referee1_id: r1.id)

      login(@admin)
      get '/api/v2/admin/referee_feedback_analytics/export.csv'

      assert_response :success
      assert_includes response.body, 'Schiedsrichter'
    end

    private

    def game_in(league, home_team: nil, guest_team: nil, home_goals: nil, guest_goals: nil, date: '2026-01-15')
      day = create(:game_day, league: league, date: date)
      if home_goals
        create(:game, :with_result, game_day: day, home_team: home_team, guest_team: guest_team,
                                     home_goals: home_goals, guest_goals: guest_goals)
      else
        create(:game, game_day: day)
      end
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
