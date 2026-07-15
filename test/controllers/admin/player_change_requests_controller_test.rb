require 'test_helper'

module Admin
  # Fokus: der neue Merge-Antragstyp (VM schlägt Zusammenführung vor,
  # Admin/SBK genehmigt und führt damit den Merge aus).
  class PlayerChangeRequestsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')

      @club = Club.create!(name: "Verein #{SecureRandom.hex(4)}")
      @other_club = Club.create!(name: "Anderer Verein #{SecureRandom.hex(4)}")

      @master = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
      @duplicate = create(:player, first_name: @master.first_name, last_name: @master.last_name)

      @vm = create_user(user_group_id: 4, club_id: @club.id)
      @vm_other = create_user(user_group_id: 4, club_id: @other_club.id)
      @admin = create_user(user_group_id: 1, game_operation_id: 0)
    end

    test 'VM legt Merge-Antrag für Spieler des eigenen Vereins an' do
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: @duplicate.id
      }

      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'pending', body['status']
      assert_equal @duplicate.id, body.dig('secondary_player', 'id')
    end

    test 'VM eines anderen Vereins darf keinen Antrag für fremden Verein anlegen' do
      login(@vm_other)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: @duplicate.id
      }

      assert_response :forbidden
    end

    test 'Merge-Antrag für Spieler, der nicht zum Verein gehört, wird abgelehnt' do
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @duplicate.id, club_id: @club.id,
        correction_type: 'merge', secondary_player_id: @master.id
      }

      assert_response :forbidden
    end

    test 'Merge-Antrag ohne secondary_player_id wird abgelehnt' do
      login(@vm)
      post '/api/v2/admin/player_change_requests.json', params: {
        player_id: @master.id, club_id: @club.id, correction_type: 'merge'
      }

      assert_response :unprocessable_entity
    end

    test 'Admin-Approve führt die Spieler zusammen' do
      request = create_merge_request
      login(@admin)
      patch "/api/v2/admin/player_change_requests/#{request.id}/approve.json"

      assert_response :success
      assert_equal 'approved', request.reload.status
      assert_equal @master.id, @duplicate.reload.merged_into_id
      assert_predicate @duplicate.deactivated_at, :present?
    end

    test 'VM darf nicht genehmigen' do
      request = create_merge_request
      login(@vm)
      patch "/api/v2/admin/player_change_requests/#{request.id}/approve.json"

      assert_response :forbidden
      assert_equal 'pending', request.reload.status
    end

    test 'Approve liefert 422, wenn das Duplikat inzwischen anderweitig gemergt wurde' do
      request = create_merge_request
      @duplicate.update_columns(merged_into_id: @master.id)

      login(@admin)
      patch "/api/v2/admin/player_change_requests/#{request.id}/approve.json"

      assert_response :unprocessable_entity
      assert_equal 'pending', request.reload.status
    end

    private

    def create_merge_request
      PlayerChangeRequest.create!(
        player: @master, club: @club, correction_type: 'merge',
        secondary_player: @duplicate, status: 'pending', requested_by_user_id: @vm.id
      )
    end

    def create_user(user_group_id:, game_operation_id: 0, club_id: nil)
      permissions = if club_id
                      [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id, 'club_id' => club_id }]
                    else
                      [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }]
                    end
      User.create!(
        user_name: "user_#{SecureRandom.hex(6)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: permissions,
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
