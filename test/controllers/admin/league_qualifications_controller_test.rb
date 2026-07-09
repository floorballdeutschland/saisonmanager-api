require 'test_helper'

module Admin
  # Regressionstests zu Issue #63: SBK mit passendem Spielbetrieb-Scope darf
  # Auf-/Abstiegsregeln pflegen (wie die Liga-Bearbeitung selbst), fremde SBK
  # sowie VM/TM bekommen 403.
  class LeagueQualificationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      sa = create(:state_association)
      # Spielbetriebe mit Landesverband, damit der SBK-Scope nicht als
      # nationaler Verband (state_association_id: nil) auf global gehoben wird.
      @go = create(:game_operation, state_association_id: sa.id)
      @other_go = create(:game_operation, state_association_id: sa.id)
      @league = create(:league, game_operation: @go)
    end

    test 'Admin darf Qualifikationsregeln anlegen' do
      login(create(:user, :admin))

      post_qualification
      assert_response :created
    end

    test 'SBK des eigenen Spielbetriebs darf Regeln anlegen, ändern und löschen' do
      login(create(:user, :sbk_scoped, game_operation_id: @go.id))

      post_qualification
      assert_response :created
      qual_id = JSON.parse(response.body)['id']

      patch "/api/v2/admin/leagues/#{@league.id}/qualifications/#{qual_id}",
            params: { league_qualification: { label: 'Aufstieg 1. FBL' } }
      assert_response :success
      assert_equal 'Aufstieg 1. FBL', JSON.parse(response.body)['label']

      delete "/api/v2/admin/leagues/#{@league.id}/qualifications/#{qual_id}"
      assert_response :no_content
      assert_not LeagueQualification.exists?(qual_id)
    end

    test 'SBK eines fremden Spielbetriebs bekommt 403' do
      login(create(:user, :sbk_scoped, game_operation_id: @other_go.id))

      post_qualification
      assert_response :forbidden
      assert_equal 0, @league.qualifications.count
    end

    test 'VM bekommt 403' do
      team = create(:team, league: @league)
      login(create(:user, :vm, club_id: team.club_id))

      post_qualification
      assert_response :forbidden
    end

    test 'TM bekommt 403' do
      team = create(:team, league: @league)
      login(create(:user, :tm, team_id: team.id))

      post_qualification
      assert_response :forbidden
    end

    private

    def post_qualification
      post "/api/v2/admin/leagues/#{@league.id}/qualifications",
           params: {
             league_qualification: {
               rank_from: 1, rank_to: 2, qualification_type: 'promotion', label: 'Aufstieg'
             }
           }
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
