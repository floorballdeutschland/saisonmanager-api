require 'test_helper'

module Admin
  class RefereesControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = User.create!(
        user_name: "refadmin_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
        teams: []
      )
    end

    test 'create legt Schiri an und stößt KEINEN Passmeister-Wallet-Versand an' do
      login(@admin)

      # Schlägt fehl, falls der (entfernte) Auto-Versand PassmeisterService doch ruft.
      called = false
      PassmeisterService.stub(:create_or_update_pass, ->(*) { called = true }) do
        assert_difference -> { Referee.count }, 1 do
          post '/api/v2/admin/referees', params: {
            referee: { lizenznummer: 987_654, vorname: 'Test', nachname: 'Schiri', email: 'test@example.org' }
          }
        end
      end

      assert_response :created
      assert_not called, 'PassmeisterService darf bei der Anlage nicht aufgerufen werden'
    end

    test 'LV-RSK darf keinen neuen Schiedsrichter anlegen' do
      login(lv_rsk_user)

      assert_no_difference -> { Referee.count } do
        post '/api/v2/admin/referees', params: {
          referee: { lizenznummer: 555_111, vorname: 'Neu', nachname: 'Schiri' }
        }
      end

      assert_response :forbidden
    end

    test 'FD-RSK darf einen neuen Schiedsrichter anlegen' do
      fd = create(:game_operation, state_association_id: nil)
      login(rsk_user(fd.id))

      assert_difference -> { Referee.count }, 1 do
        post '/api/v2/admin/referees', params: {
          referee: { lizenznummer: 555_222, vorname: 'Neu', nachname: 'Schiri' }
        }
      end

      assert_response :created
    end

    test 'LV-RSK darf für einen bestehenden Schiri ein Benutzerkonto anlegen' do
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      club = create(:club, state_association_id: sa.id)
      referee = create(:referee, club_id: club.id, email: nil)
      login(rsk_user(go.id))

      assert_difference -> { User.count }, 1 do
        post "/api/v2/admin/referees/#{referee.id}/create_user"
      end

      assert_response :success
    end

    private

    # RSK-Nutzer für einen konkreten Spielbetrieb (nationaler GO ⇒ FD/global,
    # sonst LV-gescopt).
    def rsk_user(go_id)
      User.create!(
        user_name: "rsk_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 3, 'game_operation_id' => go_id }],
        teams: []
      )
    end

    def lv_rsk_user
      sa = create(:state_association)
      go = create(:game_operation, state_association_id: sa.id)
      rsk_user(go.id)
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
