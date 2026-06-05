require 'test_helper'

module Admin
  class TransferRequestsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @game_operation = GameOperation.create!(
        name: "SBK Test #{SecureRandom.hex(4)}",
        short_name: "ST#{SecureRandom.hex(2)}"
      )

      @former_club = Club.create!(
        name: "Abgebender Verein #{SecureRandom.hex(4)}",
        short_name: "AV#{SecureRandom.hex(2)}",
        game_operations_hash: [{ 'game_operation_id' => @game_operation.id, 'home_game_operation' => true }]
      )

      @requesting_club = Club.create!(
        name: "Aufnehmender Verein #{SecureRandom.hex(4)}",
        short_name: "AU#{SecureRandom.hex(2)}",
        game_operations_hash: [{ 'game_operation_id' => @game_operation.id, 'home_game_operation' => true }]
      )

      create(:setting, current_season_id: '18')

      @player = Player.create!(
        first_name: 'Max',
        last_name: 'Mustermann',
        birthdate: '1995-03-15',
        nation_id: '1',
        gender: 'm',
        email: 'max.mustermann@example.com',
        clubs: [{ 'club_id' => @former_club.id, 'home_club' => true, 'valid_until' => nil }],
        licenses: []
      )

      @vm_requesting = create_user(user_group_id: 4, club_id: @requesting_club.id)
      @vm_former     = create_user(user_group_id: 4, club_id: @former_club.id)
      @sbk           = create_user_sbk(game_operation_id: @game_operation.id)
      @admin         = create_user(user_group_id: 1, game_operation_id: 0)
      @tm            = create_user(user_group_id: 5, game_operation_id: 0)
    end

    # ---------------------------------------------------------------------------
    # POST /api/v2/admin/transfer_requests
    # ---------------------------------------------------------------------------

    test 'VM erstellt Transferantrag → 201, Status pending_club' do
      login(@vm_requesting)
      assert_emails 1 do
        post '/api/v2/admin/transfer_requests', params: {
          player_id: @player.id,
          requesting_club_id: @requesting_club.id
        }
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'pending_club', body['status']
      assert_equal @player.id, body['player']['id']
    end

    test 'VM kann keinen Antrag für fremden Verein erstellen → 403' do
      other_club = Club.create!(
        name: "Fremder Verein #{SecureRandom.hex(4)}",
        short_name: "FR#{SecureRandom.hex(2)}"
      )
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: other_club.id
      }
      assert_response :forbidden
    end

    test 'Nicht-VM (TM) kann keinen Transferantrag erstellen → 403' do
      login(@tm)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :forbidden
    end

    test 'Spieler ohne E-Mail kann nicht beantragt werden → 422' do
      @player.update_columns(email: nil)
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
    end

    test 'Zweiter aktiver Antrag für denselben Spieler → 422' do
      existing = TransferRequest.create!(
        player: @player,
        requesting_club: @requesting_club,
        former_club: @former_club,
        status: 'pending_club',
        created_by: @vm_requesting.id,
        season_id: 18
      )
      login(@vm_requesting)
      post '/api/v2/admin/transfer_requests', params: {
        player_id: @player.id,
        requesting_club_id: @requesting_club.id
      }
      assert_response :unprocessable_entity
    ensure
      existing&.destroy
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/approve_club
    # ---------------------------------------------------------------------------

    test 'VM des abgebenden Vereins genehmigt → Status pending_player, Spieler-Mail wird versendet' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'pending_player', body['status']
      assert_equal 'pending_player', tr.reload.status
      assert tr.reload.player_confirmation_token.present?
    end

    test 'VM des aufnehmenden Vereins darf approve_club nicht ausführen → 403' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_requesting)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      assert_response :forbidden
    end

    test 'approve_club bei falschem Status → 422' do
      tr = create_transfer_request(status: 'pending_player')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_club"
      assert_response :unprocessable_entity
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/reject_club
    # ---------------------------------------------------------------------------

    test 'VM lehnt ab → Status rejected_by_club' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_club",
              params: { rejection_reason: 'Spieler wird noch benötigt' }
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'rejected_by_club', body['status']
      assert_equal 'rejected_by_club', tr.reload.status
    end

    test 'reject_club ohne Begründung → 422' do
      tr = create_transfer_request(status: 'pending_club')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_club"
      assert_response :unprocessable_entity
    end

    # ---------------------------------------------------------------------------
    # GET /api/v2/admin/transfer_requests/player_approve?token=X (kein Auth)
    # ---------------------------------------------------------------------------

    test 'Spieler bestätigt via Token → 302 Redirect, Status pending_lv' do
      tr = create_transfer_request(status: 'pending_player')
      token = tr.player_confirmation_token
      assert_emails 2 do
        get "/api/v2/admin/transfer_requests/player_approve", params: { token: token }
      end
      assert_response :redirect
      assert_match 'result=approved', response.location
      assert_equal 'pending_lv', tr.reload.status
    end

    test 'player_approve mit ungültigem Token → 302 Redirect mit result=error' do
      get '/api/v2/admin/transfer_requests/player_approve', params: { token: 'ungueltig' }
      assert_response :redirect
      assert_match 'result=error', response.location
    end

    test 'player_approve bei bereits genehmigtem Antrag → 302 Redirect mit already_approved' do
      tr = create_transfer_request(status: 'pending_lv')
      token = tr.player_confirmation_token
      get '/api/v2/admin/transfer_requests/player_approve', params: { token: token }
      assert_response :redirect
      assert_match 'already_approved', response.location
    end

    # ---------------------------------------------------------------------------
    # GET /api/v2/admin/transfer_requests/player_reject?token=X (kein Auth)
    # ---------------------------------------------------------------------------

    test 'Spieler lehnt via Token ab → 302 Redirect, Status rejected_by_player' do
      tr = create_transfer_request(status: 'pending_player')
      token = tr.player_confirmation_token
      assert_emails 1 do
        get '/api/v2/admin/transfer_requests/player_reject', params: { token: token }
      end
      assert_response :redirect
      assert_match 'result=rejected', response.location
      assert_equal 'rejected_by_player', tr.reload.status
    end

    test 'player_reject mit ungültigem Token → 302 Redirect mit result=error' do
      get '/api/v2/admin/transfer_requests/player_reject', params: { token: 'ungueltig' }
      assert_response :redirect
      assert_match 'result=error', response.location
    end

    test 'player_reject bei bereits abgelehntem Antrag → 302 Redirect mit already_rejected' do
      tr = create_transfer_request(status: 'rejected_by_player')
      token = tr.player_confirmation_token
      # Token wird bei rejected_by_player auf nil gesetzt; neuen erzeugen für Lookup-Test
      tr.update_columns(player_confirmation_token: 'dummy_already_rejected')
      get '/api/v2/admin/transfer_requests/player_reject',
          params: { token: 'dummy_already_rejected' }
      assert_response :redirect
      assert_match 'already_rejected', response.location
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/approve_lv
    # ---------------------------------------------------------------------------

    test 'SBK genehmigt LV → Status approved (sofortiger Transfer)' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'approved', body['status']
      assert_equal 'approved', tr.reload.status
    end

    test 'Admin genehmigt LV → Status approved' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      end
      assert_response :success
      assert_equal 'approved', tr.reload.status
    end

    test 'approve_lv mit zukünftigem effective_date → Status scheduled' do
      tr = create_transfer_request(status: 'pending_lv', effective_date: Date.today + 10)
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'scheduled', body['status']
      assert_equal 'scheduled', tr.reload.status
    end

    test 'VM darf approve_lv nicht ausführen → 403' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :forbidden
    end

    test 'approve_lv bei falschem Status → 422' do
      tr = create_transfer_request(status: 'pending_club')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/approve_lv"
      assert_response :unprocessable_entity
    end

    # ---------------------------------------------------------------------------
    # PATCH /api/v2/admin/transfer_requests/:id/reject_lv
    # ---------------------------------------------------------------------------

    test 'SBK lehnt LV ab → Status rejected_by_lv' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv",
              params: { rejection_reason: 'Sperrfrist noch aktiv' }
      end
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'rejected_by_lv', body['status']
      assert_equal 'rejected_by_lv', tr.reload.status
    end

    test 'Admin lehnt LV ab → Status rejected_by_lv' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@admin)
      assert_emails 1 do
        patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv",
              params: { rejection_reason: 'Administrativer Grund' }
      end
      assert_response :success
      assert_equal 'rejected_by_lv', tr.reload.status
    end

    test 'reject_lv ohne Begründung → 422' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@sbk)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv"
      assert_response :unprocessable_entity
    end

    test 'VM darf reject_lv nicht ausführen → 403' do
      tr = create_transfer_request(status: 'pending_lv')
      login(@vm_former)
      patch "/api/v2/admin/transfer_requests/#{tr.id}/reject_lv",
            params: { rejection_reason: 'Kein Zugriff' }
      assert_response :forbidden
    end

    private

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

    def create_user_sbk(game_operation_id:)
      User.create!(
        user_name: "sbk_#{SecureRandom.hex(6)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 2, 'game_operation_id' => game_operation_id }],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def create_transfer_request(status:, effective_date: nil)
      tr = TransferRequest.create!(
        player: @player,
        requesting_club: @requesting_club,
        former_club: @former_club,
        status: status,
        created_by: @vm_requesting.id,
        season_id: 18,
        effective_date: effective_date
      )
      # token wird im before_create callback generiert; bei direkt gesetztem
      # Status (z.B. pending_lv) ist er trotzdem vorhanden.
      tr
    end
  end
end
