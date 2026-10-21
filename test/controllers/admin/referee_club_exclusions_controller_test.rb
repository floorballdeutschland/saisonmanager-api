require 'test_helper'

module Admin
  class RefereeClubExclusionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)

      @sa_own = create(:state_association, referee_assignment_enabled: true)
      @go_own = create(:game_operation, state_association_id: @sa_own.id)
      @club_own = create(:club, state_association_id: @sa_own.id)
      @referee = create(:referee, club: @club_own, email: 'schiri@example.com')

      @sa_other = create(:state_association, referee_assignment_enabled: true)
      @go_other = create(:game_operation, state_association_id: @sa_other.id)
      @club_other = create(:club, state_association_id: @sa_other.id)
      @referee_other = create(:referee, club: @club_other)

      # Entscheidungsstelle ist die RSK von FD (Spielbetrieb 0), seit 2.0 nicht
      # mehr die FD-Ansetzung.
      @assigner = create(:user, :rsk_scoped, game_operation_id: 0)
      @lv_assigner = create(:user, :rsk_scoped, game_operation_id: @go_own.id)
      @fd_ansetzer = create(:user, :assigner_scoped, game_operation_id: 0)
    end

    test 'RSK FD sieht die Antraege aller Verbaende' do
      own = pending_request(@referee, @club_other)
      foreign = pending_request(@referee_other, @club_own)

      login(@assigner)
      get '/api/v2/admin/referee_club_exclusion_requests?status=pending'

      assert_response :success
      ids = JSON.parse(response.body).map { |r| r['id'] }
      assert_includes ids, own.id
      assert_includes ids, foreign.id
    end

    # Die Antragsmail geht an die RSK von FD, dort wird entschieden. Eine LV-RSK
    # soll die Antraege deshalb gar nicht erst sehen, auch nicht die ihrer
    # eigenen Schiris.
    test 'LV-RSK hat keinen Zugriff auf die Antraege' do
      request = pending_request(@referee, @club_other)

      login(@lv_assigner)
      get '/api/v2/admin/referee_club_exclusion_requests?status=pending'
      assert_response :forbidden

      post "/api/v2/admin/referee_club_exclusion_requests/#{request.id}/approve"
      assert_response :forbidden
      assert_equal 'pending', request.reload.status
    end

    test 'LV-RSK pflegt die Liste auch nicht direkt' do
      login(@lv_assigner)

      post "/api/v2/admin/referees/#{@referee.id}/club_exclusions",
           params: { exclusion: { club_id: @club_other.id, reason: 'Absprache' } }

      assert_response :forbidden
      assert_not RefereeClubExclusion.exists?(referee_id: @referee.id, club_id: @club_other.id)
    end

    # Bis 2.0 entschied die FD-Ansetzung. Sie liest die Liste weiter als
    # Warnung in der Ansetzung, pflegt und entscheidet aber nicht mehr.
    test 'FD-Ansetzer entscheidet und pflegt nicht mehr' do
      request = pending_request(@referee, @club_other)
      login(@fd_ansetzer)

      get '/api/v2/admin/referee_club_exclusion_requests?status=pending'
      assert_response :forbidden

      post "/api/v2/admin/referee_club_exclusion_requests/#{request.id}/approve"
      assert_response :forbidden
      assert_equal 'pending', request.reload.status

      post "/api/v2/admin/referees/#{@referee.id}/club_exclusions",
           params: { exclusion: { club_id: @club_other.id, reason: 'Absprache' } }
      assert_response :forbidden
      assert_not RefereeClubExclusion.exists?(referee_id: @referee.id, club_id: @club_other.id)
    end

    test 'Menuepunkt nur fuer Admin und RSK FD' do
      assert @assigner.permissions_items[:menu_item_referee_exclusions]
      assert_not @fd_ansetzer.permissions_items[:menu_item_referee_exclusions]
      assert_not @lv_assigner.permissions_items[:menu_item_referee_exclusions]
    end

    test 'SBK hat keinen Zugriff' do
      login(create(:user, :sbk_global))
      get '/api/v2/admin/referee_club_exclusion_requests'

      assert_response :forbidden
    end

    test 'Genehmigen legt den Ausschluss an und benachrichtigt den Schiri' do
      request = pending_request(@referee, @club_other)

      login(@assigner)
      assert_enqueued_emails 1 do
        post "/api/v2/admin/referee_club_exclusion_requests/#{request.id}/approve"
      end

      assert_response :success
      assert_equal 'approved', request.reload.status
      assert RefereeClubExclusion.exists?(referee_id: @referee.id, club_id: @club_other.id)
    end

    test 'Ablehnen ohne Begruendung wird abgewiesen' do
      request = pending_request(@referee, @club_other)

      login(@assigner)
      post "/api/v2/admin/referee_club_exclusion_requests/#{request.id}/reject"

      assert_response :unprocessable_entity
      assert_equal 'pending', request.reload.status
    end

    test 'Ablehnen mit Begruendung schliesst den Antrag ohne Listeneintrag' do
      request = pending_request(@referee, @club_other)

      login(@assigner)
      post "/api/v2/admin/referee_club_exclusion_requests/#{request.id}/reject",
           params: { decision_note: 'Kein Ausschlussgrund' }

      assert_response :success
      assert_equal 'rejected', request.reload.status
      assert_equal 'Kein Ausschlussgrund', request.decision_note
      assert_not RefereeClubExclusion.exists?(referee_id: @referee.id, club_id: @club_other.id)
    end

    test 'Antrag eines Schiris aus einem anderen Verband ist entscheidbar' do
      foreign = pending_request(@referee_other, @club_own)

      login(@assigner)
      post "/api/v2/admin/referee_club_exclusion_requests/#{foreign.id}/approve"

      assert_response :success
      assert_equal 'approved', foreign.reload.status
    end

    test 'FD-Ansetzer pflegt die Liste eines Schiris direkt' do
      login(@assigner)

      post "/api/v2/admin/referees/#{@referee.id}/club_exclusions",
           params: { exclusion: { club_id: @club_other.id, reason: 'Absprache RSK' } }

      assert_response :created
      exclusion = RefereeClubExclusion.find_by(referee_id: @referee.id, club_id: @club_other.id)
      assert_not_nil exclusion
      assert_equal @assigner.id, exclusion.created_by

      delete "/api/v2/admin/referees/#{@referee.id}/club_exclusions/#{exclusion.id}"

      assert_response :success
      assert_nil RefereeClubExclusion.find_by(id: exclusion.id)
    end

    test 'eigener Verein laesst sich auch direkt nicht eintragen' do
      login(@assigner)

      post "/api/v2/admin/referees/#{@referee.id}/club_exclusions",
           params: { exclusion: { club_id: @club_own.id, reason: 'Doppelt' } }

      assert_response :unprocessable_entity
      assert_not RefereeClubExclusion.exists?(referee_id: @referee.id, club_id: @club_own.id)
    end

    test 'Liste eines Schiris aus einem anderen Verband ist abrufbar' do
      login(@assigner)
      get "/api/v2/admin/referees/#{@referee_other.id}/club_exclusions"

      assert_response :success
    end

    private

    def pending_request(referee, club)
      RefereeClubExclusionRequest.create!(referee: referee, club: club, kind: 'add', reason: 'Befangenheit')
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
