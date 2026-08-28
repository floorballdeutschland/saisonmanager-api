require 'test_helper'

module Admin
  class RefereeObservationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @referee = create(:referee)
      @observation = create(:referee_observation, :with_rating, rated_referee: @referee)
      @go_id = @observation.game_operation_id
    end

    test 'Admin sieht die Boegen eines Schiedsrichters samt Schnitt seiner eigenen Bewertungen' do
      login(create(:user, :admin))
      get "/api/v2/admin/referees/#{@referee.id}/observations"
      assert_response :success

      body = JSON.parse(response.body)
      assert_equal 1, body['summary']['count']
      assert_equal 5.0, body['summary']['overall_rating']
      assert_equal 1, body['observations'].size
      assert_equal @observation.id, body['observations'].first['id']
    end

    test 'LV-RSK des eigenen Spielbetriebs sieht den Bogen' do
      login(create(:user, :rsk_scoped, game_operation_id: @go_id))
      get "/api/v2/admin/referees/#{@referee.id}/observations"
      assert_response :success
      assert_equal 1, JSON.parse(response.body)['observations'].size
    end

    test 'LV-RSK eines fremden Spielbetriebs sieht den Bogen nicht' do
      login(create(:user, :rsk_scoped, game_operation_id: create(:game_operation).id))
      get "/api/v2/admin/referees/#{@referee.id}/observations"
      assert_response :success
      assert_empty JSON.parse(response.body)['observations']
    end

    test 'SBK hat keinen Zugriff' do
      login(create(:user, :sbk_global))
      get "/api/v2/admin/referees/#{@referee.id}/observations"
      assert_response :forbidden
    end

    test 'RSK nimmt einen Bogen zurueck und stellt ihn wieder her' do
      user = create(:user, :rsk_scoped, game_operation_id: @go_id)
      login(user)

      patch "/api/v2/admin/referee_observations/#{@observation.id}", params: { status: 'hidden' }
      assert_response :no_content
      assert_equal 'hidden', @observation.reload.status

      patch "/api/v2/admin/referee_observations/#{@observation.id}", params: { status: 'visible' }
      assert_response :no_content
      assert_equal 'visible', @observation.reload.status
    end

    test 'unbekannter Status wird abgewiesen' do
      login(create(:user, :admin))
      patch "/api/v2/admin/referee_observations/#{@observation.id}", params: { status: 'geloescht' }
      assert_response :unprocessable_entity
      assert_equal 'visible', @observation.reload.status
    end

    test 'Ansetzer darf lesen, aber nicht zuruecknehmen' do
      login(create(:user, :assigner_scoped, game_operation_id: @go_id))

      get "/api/v2/admin/referees/#{@referee.id}/observations"
      assert_response :success

      patch "/api/v2/admin/referee_observations/#{@observation.id}", params: { status: 'hidden' }
      assert_response :forbidden
      assert_equal 'visible', @observation.reload.status
    end

    test 'RSK eines fremden Spielbetriebs kann den Bogen nicht zuruecknehmen' do
      login(create(:user, :rsk_scoped, game_operation_id: create(:game_operation).id))
      patch "/api/v2/admin/referee_observations/#{@observation.id}", params: { status: 'hidden' }
      assert_response :not_found
      assert_equal 'visible', @observation.reload.status
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
