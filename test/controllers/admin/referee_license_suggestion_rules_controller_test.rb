require 'test_helper'

module Admin
  class RefereeLicenseSuggestionRulesControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @l1 = RefereeLicenseLevel.create!(name: 'L1', validity_years: 1)
      create(:league, age_group: 'U17 Junioren')
    end

    test 'Admin pflegt Regeln und bekommt die Auswahllisten' do
      login(create(:user, :admin))

      post '/api/v2/admin/referee_license_suggestion_rules',
           params: { rule: { course_type: 'f', referee_license_level_id: @l1.id, position: 1, min_games: 4,
                             field_size: 'GF', age_groups: ['U17 Junioren', ''] } }, as: :json
      assert_response :created
      id = response.parsed_body['id']
      assert_equal ['U17 Junioren'], response.parsed_body['age_groups']

      put "/api/v2/admin/referee_license_suggestion_rules/#{id}", params: { rule: { min_games: 5 } }, as: :json
      assert_response :success
      assert_equal 5, RefereeLicenseSuggestionRule.find(id).min_games

      get '/api/v2/admin/referee_license_suggestion_rules'
      assert_response :success
      assert_equal([id], response.parsed_body['rules'].map { |r| r['id'] })
      assert_includes response.parsed_body['age_groups'], 'U17 Junioren'
      assert_includes response.parsed_body['course_types'], 'f'

      delete "/api/v2/admin/referee_license_suggestion_rules/#{id}"
      assert_response :no_content
    end

    test 'ungueltige Feldgroesse wird abgewiesen' do
      login(create(:user, :admin))

      post '/api/v2/admin/referee_license_suggestion_rules',
           params: { rule: { course_type: 'f', referee_license_level_id: @l1.id, field_size: 'XL' } }, as: :json

      assert_response :unprocessable_entity
    end

    test 'FD-RSK darf die Regeln nicht pflegen' do
      login(create(:user, permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 0 }]))

      get '/api/v2/admin/referee_license_suggestion_rules'

      assert_response :forbidden
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
