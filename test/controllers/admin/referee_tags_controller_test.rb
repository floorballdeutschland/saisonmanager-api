require 'test_helper'

module Admin
  class RefereeTagsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      # FD ist ein nationaler Spielbetrieb (kein state_association_id) und wird im
      # permission_hash auf den globalen Scope 0 abgebildet.
      @fd = create(:game_operation, state_association_id: nil)
      @sa = create(:state_association)
      @lv_go = create(:game_operation, state_association_id: @sa.id)
    end

    test 'FD-RSK legt einen Tag als FD-eigenen (nicht globalen) Tag an' do
      login(rsk_user(@fd.id))

      post '/api/v2/admin/referee_tags', params: {
        referee_tag: { name: 'Spitzenschiri', color: '#ff0000' }
      }

      assert_response :created
      body = JSON.parse(response.body)
      assert_equal @fd.id, body['game_operation_id'],
                   'FD-Tag muss an den FD-Spielbetrieb gebunden sein, nicht global (nil)'
    end

    test 'LV-RSK sieht FD-eigene Tags nicht' do
      RefereeTag.create!(name: 'FD-Only', game_operation_id: @fd.id)
      login(rsk_user(@lv_go.id))

      get '/api/v2/admin/referee_tags'

      assert_response :success
      names = JSON.parse(response.body).map { |t| t['name'] }
      assert_not_includes names, 'FD-Only'
    end

    test 'LV-RSK sieht globale Tags' do
      RefereeTag.create!(name: 'Global', game_operation_id: nil)
      login(rsk_user(@lv_go.id))

      get '/api/v2/admin/referee_tags'

      assert_response :success
      names = JSON.parse(response.body).map { |t| t['name'] }
      assert_includes names, 'Global'
    end

    test 'LV-RSK darf einen globalen Tag nicht verwalten' do
      tag = RefereeTag.create!(name: 'Global', game_operation_id: nil)
      login(rsk_user(@lv_go.id))

      put "/api/v2/admin/referee_tags/#{tag.id}", params: {
        referee_tag: { name: 'Umbenannt' }
      }

      assert_response :forbidden
      assert_equal 'Global', tag.reload.name
    end

    private

    def rsk_user(go_id)
      User.create!(
        user_name: "rsk_#{SecureRandom.hex(4)}",
        password: 'password123',
        password_confirmation: 'password123',
        permissions: [{ 'user_group_id' => 3, 'game_operation_id' => go_id }],
        teams: []
      )
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
