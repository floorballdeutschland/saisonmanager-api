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

    # Der Test darueber greift die Doppelrolle NICHT ab: Die Fabrik :rsk_scoped
    # legt ein Konto ohne Schiedsrichterprofil an, und genau das Profil war die
    # Luecke. Ein aktiver Schiedsrichter mit einer RSK-Rolle irgendwo ist der
    # Normalfall, kein Sonderfall.
    test 'beobachtete Person mit RSK-Rolle nimmt den Bogen ueber sich selbst nicht zurueck' do
      login(create(:user, :rsk_scoped, game_operation_id: create(:game_operation).id,
                                       referee: @referee))

      patch "/api/v2/admin/referee_observations/#{@observation.id}", params: { status: 'hidden' }
      assert_response :not_found
      assert_equal 'visible', @observation.reload.status,
                   'Wer beobachtet wurde, darf die Kritik an sich selbst nicht aus der Welt nehmen'
    end

    test 'Coach mit RSK-Rolle nimmt den eigenen Bogen in einem fremden Spielbetrieb nicht zurueck' do
      coach_user = create(:user, :rsk_scoped, game_operation_id: create(:game_operation).id,
                                              referee: @observation.coach)
      login(coach_user)

      patch "/api/v2/admin/referee_observations/#{@observation.id}", params: { status: 'hidden' }
      assert_response :not_found
      assert_equal 'visible', @observation.reload.status
    end

    # Die Verwaltungssicht serialisiert den vollstaendigen Bogen, also auch die
    # Einzelnoten des Gespannpartners. Sie darf deshalb ausschliesslich aus der
    # Rollensicht schoepfen: Wuerde die eigene Betroffenheit sie mit aufspannen,
    # laese jeder Schiedsrichter mit irgendeiner Rolle ueber das Profil seines
    # Partners dessen Noten mit -- quer ueber jede Verbandsgrenze.
    test 'beobachtete Person mit Rolle liest ueber die Verwaltung nicht die Noten des Gespannpartners' do
      partner = create(:referee)
      @observation.ratings.create!(referee: partner, position: 2, stick_play_rating: 2,
                                   physical_play_rating: 2, penalty_line_rating: 2,
                                   game_management_rating: 2, overall_rating: 2)
      login(create(:user, :rsk_scoped, game_operation_id: create(:game_operation).id,
                                       referee: @referee))

      get "/api/v2/admin/referees/#{partner.id}/observations"
      assert_response :success

      body = JSON.parse(response.body)
      rated = body['observations'].flat_map { |o| o['ratings'] }.map { |r| r['referee_id'] }
      assert_not_includes rated, partner.id,
                          'Die Noten des Gespannpartners gehoeren nicht in die Verwaltungssicht ' \
                          'eines Kontos, dessen Rolle den Spielbetrieb gar nicht umfasst'
      assert_empty body['observations']
      assert_equal 0, body['summary']['count']
    end

    test 'reines Schiedsrichterkonto hat keine Verwaltungssicht auf die eigenen Boegen' do
      login(create(:user, referee: @referee,
                          permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }]))
      get "/api/v2/admin/referees/#{@referee.id}/observations"
      assert_response :forbidden
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
