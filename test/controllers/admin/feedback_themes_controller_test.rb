require 'test_helper'

module Admin
  class FeedbackThemesControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @fd = create(:game_operation, state_association_id: nil)
      @lv_sa = create(:state_association)
      @lv_go = create(:game_operation, state_association_id: @lv_sa.id)
    end

    test 'LV-RSK darf die Themen-Taxonomie nicht sehen' do
      login(create(:user, :rsk_scoped, game_operation_id: @lv_go.id))
      get '/api/v2/admin/feedback_themes'
      assert_response :forbidden
    end

    test 'FD-RSK legt ein Thema an und sieht es mit Nutzungszähler' do
      login(create(:user, :rsk_scoped, game_operation_id: @fd.id))

      post '/api/v2/admin/feedback_themes', params: { feedback_theme: { name: 'Positionierung' } }
      assert_response :created

      get '/api/v2/admin/feedback_themes'
      assert_response :success
      entry = response.parsed_body.find { |t| t['name'] == 'Positionierung' }
      assert_equal 0, entry['usage_count']
    end

    test 'Doppelter Name wird abgelehnt' do
      create(:feedback_theme, name: 'Auftreten')
      login(@admin)

      assert_no_difference -> { FeedbackTheme.count } do
        post '/api/v2/admin/feedback_themes', params: { feedback_theme: { name: 'auftreten' } }
      end
      assert_response :unprocessable_entity
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
