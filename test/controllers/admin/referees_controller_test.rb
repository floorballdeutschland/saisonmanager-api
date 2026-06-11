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

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
