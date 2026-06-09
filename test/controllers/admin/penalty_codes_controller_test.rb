require 'test_helper'

module Admin
  class PenaltyCodesControllerTest < ActionDispatch::IntegrationTest
    setup do
      @setting = create(:setting, penalty_codes: {
                          '5' => { 'code' => '201', 'description' => 'Beinstellen', 'active' => true },
                          '6' => { 'code' => '902', 'description' => 'Stockschlag', 'active' => false }
                        })
      @admin = create_user(user_group_id: 1, game_operation_id: 0)
      @vm    = create_user(user_group_id: 4, game_operation_id: 0)
    end

    test 'index liefert alle Codes (auch inaktive), nach Code sortiert' do
      login(@admin)
      get '/api/v2/admin/penalty_codes'
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal %w[201 902], body.map { |e| e['code'] }.sort
    end

    test 'index toleriert Legacy-Einträge ohne code/description (kein 500)' do
      # Alt-Bestand: ältere Einträge tragen nur {"name"=>...} ohne code/active.
      @setting.update!(penalty_codes: @setting.penalty_codes.merge(
        '1' => { 'name' => 'Behinderung' }
      ))
      login(@admin)
      get '/api/v2/admin/penalty_codes'
      assert_response :success
      body = JSON.parse(response.body)
      legacy = body.find { |e| e['id'] == '1' }
      assert_equal '', legacy['code']
      assert_equal 'Behinderung', legacy['description']
      assert_equal false, legacy['active']
    end

    test 'create vergibt id = max+1 und reindiziert nicht' do
      login(@admin)
      post '/api/v2/admin/penalty_codes', params: { penalty_code: { code: '533', description: 'Halten' } }
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal '7', body['id'] # max(5,6)+1
      assert_equal '533', body['code']
      assert body['active']
      # Bestehende ids unverändert
      assert_equal 'Beinstellen', @setting.reload.penalty_codes['5']['description']
    end

    test 'create lehnt nicht-3-stelligen Code ab' do
      login(@admin)
      post '/api/v2/admin/penalty_codes', params: { penalty_code: { code: '90', description: 'X' } }
      assert_response :unprocessable_entity
    end

    test 'create lehnt doppelten Code ab' do
      login(@admin)
      post '/api/v2/admin/penalty_codes', params: { penalty_code: { code: '201', description: 'Dup' } }
      assert_response :unprocessable_entity
    end

    test 'update ändert Bezeichnung und active-Flag' do
      login(@admin)
      put '/api/v2/admin/penalty_codes/6', params: { penalty_code: { description: 'Stockschlag (schwer)', active: true } }
      assert_response :success
      entry = @setting.reload.penalty_codes['6']
      assert_equal 'Stockschlag (schwer)', entry['description']
      assert_equal true, entry['active']
    end

    test 'destroy entfernt Eintrag, lässt andere ids unberührt' do
      login(@admin)
      delete '/api/v2/admin/penalty_codes/5'
      assert_response :no_content
      codes = @setting.reload.penalty_codes
      assert_not codes.key?('5')
      assert codes.key?('6')
    end

    test 'VM ohne Admin-Recht → 403' do
      login(@vm)
      get '/api/v2/admin/penalty_codes'
      assert_response :forbidden
    end

    private

    def create_user(user_group_id:, game_operation_id:)
      User.create!(
        user_name: "penaltyuser_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
