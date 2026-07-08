require 'test_helper'

module Admin
  class ArenasControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @arena = create(:arena)
    end

    test 'SBK darf einen Spielort weiterhin bearbeiten' do
      login(create(:user, :sbk_scoped))

      put "/api/v2/admin/arenas/#{@arena.id}", params: { name: 'Neue Halle', city: @arena.city }

      assert_response :success
      assert_equal 'Neue Halle', @arena.reload.name
    end

    test 'SBK darf einen Spielort nicht löschen' do
      login(create(:user, :sbk_global))

      assert_no_difference -> { Arena.count } do
        delete "/api/v2/admin/arenas/#{@arena.id}"
      end

      assert_response :forbidden
    end

    test 'SBK darf Spielorte nicht zusammenführen' do
      secondary = create(:arena)
      login(create(:user, :sbk_global))

      assert_no_difference -> { Arena.count } do
        post "/api/v2/admin/arenas/#{@arena.id}/merge", params: { secondary_id: secondary.id }
      end

      assert_response :forbidden
    end

    test 'Admin darf einen Spielort löschen' do
      login(create(:user, :admin))

      assert_difference -> { Arena.count }, -1 do
        delete "/api/v2/admin/arenas/#{@arena.id}"
      end

      assert_response :no_content
    end

    test 'Admin darf Spielorte zusammenführen' do
      secondary = create(:arena)
      login(create(:user, :admin))

      post "/api/v2/admin/arenas/#{@arena.id}/merge", params: { secondary_id: secondary.id }

      assert_response :success
      assert_nil Arena.find_by(id: secondary.id)
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
