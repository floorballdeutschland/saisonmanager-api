require 'test_helper'

# Entschieden werden Stammdaten-Korrekturen von der RSK des Landesverbands, in
# dem der Verein des Schiris liegt.
module Admin
  class RefereeChangeRequestsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @lv = create(:state_association, rsk_email: 'rsk@lv.example')
      @go = create(:game_operation, state_association: @lv)
      @club = create(:club, name: 'Eigener Verein', state_association: @lv)

      @fremd_lv = create(:state_association)
      @fremd_go = create(:game_operation, state_association: @fremd_lv)
      @fremd_club = create(:club, name: 'Fremder Verein', state_association: @fremd_lv)

      @referee = create(:referee, vorname: 'Anna', nachname: 'Beispiel',
                                  club: @club, email: 'schiri@example.com')
      @fremder_referee = create(:referee, club: @fremd_club, email: 'fremd@example.com')

      @antrag = create_request(@referee, 'nachname', 'Musterfrau')
      @fremder_antrag = create_request(@fremder_referee, 'nachname', 'Fremd')
    end

    test 'RSK des Verbands sieht nur die eigenen Antraege' do
      login(rsk_user(@go.id))
      get '/api/v2/admin/referee_change_requests', params: { status: 'pending' }

      assert_response :success
      ids = JSON.parse(response.body).map { |r| r['id'] }
      assert_equal [@antrag.id], ids
    end

    test 'globale RSK sieht alle Antraege' do
      login(create(:user, permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 0 }]))
      get '/api/v2/admin/referee_change_requests'

      assert_response :success
      ids = JSON.parse(response.body).map { |r| r['id'] }
      assert_includes ids, @antrag.id
      assert_includes ids, @fremder_antrag.id
    end

    test 'Genehmigung uebernimmt den Wert und benachrichtigt den Schiri' do
      login(rsk_user(@go.id))

      assert_enqueued_emails 1 do
        post "/api/v2/admin/referee_change_requests/#{@antrag.id}/approve",
             params: { decision_note: 'Urkunde lag vor' }
      end

      assert_response :success
      assert_equal 'Musterfrau', @referee.reload.nachname
      assert_equal 'approved', @antrag.reload.status
    end

    test 'Ablehnung braucht eine Begruendung' do
      login(rsk_user(@go.id))

      post "/api/v2/admin/referee_change_requests/#{@antrag.id}/reject", params: { decision_note: ' ' }

      assert_response :unprocessable_entity
      assert_equal 'pending', @antrag.reload.status
    end

    test 'Ablehnung laesst das Profil unveraendert' do
      login(rsk_user(@go.id))

      post "/api/v2/admin/referee_change_requests/#{@antrag.id}/reject",
           params: { decision_note: 'Nachweis fehlt' }

      assert_response :success
      assert_equal 'Beispiel', @referee.reload.nachname
      assert_equal 'rejected', @antrag.reload.status
    end

    test 'zweite Entscheidung meldet den bereits entschiedenen Antrag' do
      login(rsk_user(@go.id))
      @antrag.approve!(1)

      post "/api/v2/admin/referee_change_requests/#{@antrag.id}/approve"

      assert_response :unprocessable_entity
    end

    test 'fremde Antraege sind fuer die RSK nicht entscheidbar' do
      login(rsk_user(@go.id))

      post "/api/v2/admin/referee_change_requests/#{@fremder_antrag.id}/approve"

      assert_response :not_found
      assert_equal 'pending', @fremder_antrag.reload.status
    end

    test 'die Ansetzer-Rolle entscheidet keine Stammdaten' do
      login(create(:user, :assigner_scoped, game_operation_id: @go.id))

      get '/api/v2/admin/referee_change_requests'
      assert_response :forbidden

      post "/api/v2/admin/referee_change_requests/#{@antrag.id}/approve"
      assert_response :forbidden
    end

    test 'Vereinswechsel verschiebt den Schiri in den neuen Verband' do
      antrag = create_request(@referee, 'verein', nil, new_club: @fremd_club)
      login(rsk_user(@go.id))

      post "/api/v2/admin/referee_change_requests/#{antrag.id}/approve"

      assert_response :success
      assert_equal @fremd_club.id, @referee.reload.club_id
    end

    private

    def create_request(referee, correction_type, new_value, new_club: nil)
      RefereeChangeRequest.create!(referee: referee, correction_type: correction_type,
                                   new_value: new_value, new_club: new_club)
    end

    def rsk_user(game_operation_id)
      create(:user, :rsk_scoped, game_operation_id: game_operation_id)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
