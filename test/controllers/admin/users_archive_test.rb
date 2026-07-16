require 'test_helper'

module Admin
  # Tests für das Archivieren/Reaktivieren von Benutzerkonten
  # (Admin::UsersController#archive/#unarchive) inkl. Login-Sperre.
  class UsersArchiveTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @admin = create(:user, :admin)
      @target = create(:user, :vm)
    end

    test 'Admin archiviert ein VM-Konto' do
      login(@admin)

      post "/api/v2/admin/users/#{@target.id}/archive"
      assert_response :success

      @target.reload
      assert @target.archived?
      assert_equal @admin.id, @target.archived_by
      refute_nil JSON.parse(response.body)['archived_at']
    end

    test 'eigenes Konto kann nicht archiviert werden' do
      login(@admin)

      post "/api/v2/admin/users/#{@admin.id}/archive"
      assert_response :forbidden
      refute @admin.reload.archived?
    end

    test 'doppeltes Archivieren wird abgelehnt' do
      @target.archive!(@admin.id)
      login(@admin)

      post "/api/v2/admin/users/#{@target.id}/archive"
      assert_response :unprocessable_entity
    end

    test 'archiviertes Konto kann sich nicht einloggen' do
      @target.archive!(@admin.id)

      post '/api/v2/login', params: { username: @target.user_name, password: 'password123' }
      assert_response :unauthorized
      assert_equal 'Dieses Benutzerkonto wurde archiviert.', JSON.parse(response.body)['message']
    end

    test 'laufende Session eines archivierten Kontos endet mit 401' do
      login(@target)
      get '/api/v2/admin/users'
      assert_response :success

      @target.archive!(@admin.id)

      get '/api/v2/admin/users'
      assert_response :unauthorized
    end

    test 'Reaktivieren macht das Konto wieder nutzbar' do
      @target.archive!(@admin.id)
      login(@admin)

      post "/api/v2/admin/users/#{@target.id}/unarchive"
      assert_response :success
      post '/api/v2/logout'

      @target.reload
      refute @target.archived?
      assert_nil @target.archived_by

      login(@target)
    end

    test 'Reaktivieren eines nicht archivierten Kontos wird abgelehnt' do
      login(@admin)

      post "/api/v2/admin/users/#{@target.id}/unarchive"
      assert_response :unprocessable_entity
    end

    test 'VM archiviert TM-Konto des eigenen Vereins' do
      club = create(:club)
      vm = create(:user, :vm, club_id: club.id)
      tm = create(:user, :tm)
      tm.update!(club_id: club.id)

      login(vm)
      post "/api/v2/admin/users/#{tm.id}/archive"
      assert_response :success
      assert tm.reload.archived?
    end

    test 'VM kann fremde Konten nicht archivieren' do
      club = create(:club)
      other_club = create(:club)
      vm = create(:user, :vm, club_id: club.id)
      foreign_tm = create(:user, :tm)
      foreign_tm.update!(club_id: other_club.id)

      login(vm)
      post "/api/v2/admin/users/#{foreign_tm.id}/archive"
      assert_response :not_found
      refute foreign_tm.reload.archived?
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
