require 'test_helper'

module Admin
  # Rollenvergabe durch SBK und RSK (statt nur durch Admin): Wer darf welche
  # Rolle in welchem Spielbetrieb vergeben, erweitern und wieder entziehen?
  # Grundlage ist User::ASSIGNABLE_ROLE_IDS plus der Verbund-Scope aus
  # User#permission_hash (national gescopte Konten sind dort global).
  class UsersRoleAssignmentTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting, current_season_id: '18')
      @lv = create(:game_operation)
      @other_lv = create(:game_operation)
      @fd = create(:game_operation, :national)

      @sbk_lv = create(:user, :sbk_scoped, game_operation_id: @lv.id)
      @sbk_fd = create(:user, :sbk_scoped, game_operation_id: @fd.id)
      @rsk_lv = create(:user, :rsk_scoped, game_operation_id: @lv.id)
    end

    # --- Anlegen ------------------------------------------------------------

    test 'SBK des Landesverbands legt RSK-Konto im eigenen Verbund an' do
      login(@sbk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'neue.rsk', first_name: 'Neue', last_name: 'RSK', email: 'rsk@example.org' },
        role: { user_group_id: 3, game_operation_id: @lv.id }
      }
      assert_response :created

      created = User.find_by(user_name: 'neue.rsk')
      assert_equal [{ 'user_group_id' => 3, 'game_operation_id' => @lv.id.to_s }], created.permissions
    end

    test 'SBK des Landesverbands legt SBK-Konto im eigenen Verbund an' do
      login(@sbk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'neuer.sbk', first_name: 'Neuer', last_name: 'SBK', email: 'sbk@example.org' },
        role: { user_group_id: 2, game_operation_id: @lv.id }
      }
      assert_response :created
    end

    test 'SBK des Landesverbands legt kein Konto in einem fremden Verbund an' do
      login(@sbk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'fremder.sbk', first_name: 'Fremder', last_name: 'SBK', email: 'fremd@example.org' },
        role: { user_group_id: 2, game_operation_id: @other_lv.id }
      }
      assert_response :forbidden
      assert_nil User.find_by(user_name: 'fremder.sbk')
    end

    test 'SBK vergibt keine Admin-Rolle' do
      login(@sbk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'neuer.admin', first_name: 'Neuer', last_name: 'Admin', email: 'admin@example.org' },
        role: { user_group_id: 1, game_operation_id: @lv.id }
      }
      assert_response :forbidden
      assert_nil User.find_by(user_name: 'neuer.admin')
    end

    test 'national gescopter SBK legt SBK-Konto für einen Landesverband an' do
      login(@sbk_fd)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'lv.sbk', first_name: 'LV', last_name: 'SBK', email: 'lvsbk@example.org' },
        role: { user_group_id: 2, game_operation_id: @lv.id }
      }
      assert_response :created

      created = User.find_by(user_name: 'lv.sbk')
      assert_equal @lv.id.to_s, created.permissions.first['game_operation_id']
    end

    test 'RSK legt Ansetzer-Konto im eigenen Verbund an' do
      login(@rsk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'neuer.ansetzer', first_name: 'Neuer', last_name: 'Ansetzer', email: 'ans@example.org' },
        role: { user_group_id: 7, game_operation_id: @lv.id }
      }
      assert_response :created

      created = User.find_by(user_name: 'neuer.ansetzer')
      assert_equal 7, created.permissions.first['user_group_id']
    end

    test 'RSK vergibt keine SBK-Rolle' do
      login(@rsk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'rsk.macht.sbk', first_name: 'Kein', last_name: 'SBK', email: 'kein@example.org' },
        role: { user_group_id: 2, game_operation_id: @lv.id }
      }
      assert_response :forbidden
      assert_nil User.find_by(user_name: 'rsk.macht.sbk')
    end

    test 'RSK legt kein Konto in einem fremden Verbund an' do
      login(@rsk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'fremde.rsk', first_name: 'Fremde', last_name: 'RSK', email: 'fremdrsk@example.org' },
        role: { user_group_id: 3, game_operation_id: @other_lv.id }
      }
      assert_response :forbidden
      assert_nil User.find_by(user_name: 'fremde.rsk')
    end

    test 'RSK legt kein VM-Konto an' do
      club = create(:club)
      login(@rsk_lv)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'rsk.macht.vm', first_name: 'Kein', last_name: 'VM', email: 'keinvm@example.org' },
        role: { user_group_id: 4, club_id: club.id }
      }
      assert_response :forbidden
      assert_nil User.find_by(user_name: 'rsk.macht.vm')
    end

    test 'VM mit zusätzlicher RSK-Rolle legt ein Ansetzer-Konto an' do
      club = create(:club)
      vm_rsk = create(:user, permissions: [
        { 'user_group_id' => 4, 'club_id' => club.id.to_s },
        { 'user_group_id' => 3, 'game_operation_id' => @lv.id.to_s }
      ])
      login(vm_rsk)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'vmrsk.ansetzer', first_name: 'Doppel', last_name: 'Rolle', email: 'dr@example.org' },
        role: { user_group_id: 7, game_operation_id: @lv.id }
      }
      assert_response :created

      created = User.find_by(user_name: 'vmrsk.ansetzer')
      assert_equal @lv.id.to_s, created.permissions.first['game_operation_id']
    end

    test 'reine VM legt weiterhin nur VM- und TM-Konten an' do
      club = create(:club)
      vm = create(:user, :vm, club_id: club.id)
      login(vm)

      post '/api/v2/admin/users', params: {
        user: { user_name: 'vm.macht.rsk', first_name: 'Kein', last_name: 'RSK', email: 'keinrsk@example.org' },
        role: { user_group_id: 3, game_operation_id: @lv.id }
      }
      assert_response :forbidden
      assert_nil User.find_by(user_name: 'vm.macht.rsk')
    end

    # --- Rollen erweitern ---------------------------------------------------

    test 'RSK ergänzt eine Ansetzer-Rolle im eigenen Verbund' do
      target = create(:user, :rsk_scoped, game_operation_id: @lv.id)
      login(@rsk_lv)

      post "/api/v2/admin/users/#{target.id}/add_role", params: {
        user_group_id: 7, game_operation_id: @lv.id
      }
      assert_response :success

      assert_equal [3, 7], target.reload.permissions.map { |p| p['user_group_id'].to_i }.sort
    end

    test 'RSK ergänzt keine Rolle in einem fremden Verbund' do
      target = create(:user, :rsk_scoped, game_operation_id: @lv.id)
      login(@rsk_lv)

      post "/api/v2/admin/users/#{target.id}/add_role", params: {
        user_group_id: 7, game_operation_id: @other_lv.id
      }
      assert_response :forbidden
      assert_equal([3], target.reload.permissions.map { |p| p['user_group_id'].to_i })
    end

    test 'RSK ergänzt keine SBK-Rolle' do
      target = create(:user, :rsk_scoped, game_operation_id: @lv.id)
      login(@rsk_lv)

      post "/api/v2/admin/users/#{target.id}/add_role", params: {
        user_group_id: 2, game_operation_id: @lv.id
      }
      assert_response :forbidden
      assert_equal([3], target.reload.permissions.map { |p| p['user_group_id'].to_i })
    end

    test 'RSK verwaltet keine SBK-Konten' do
      target = create(:user, :sbk_scoped, game_operation_id: @lv.id)
      login(@rsk_lv)

      post "/api/v2/admin/users/#{target.id}/add_role", params: {
        user_group_id: 7, game_operation_id: @lv.id
      }
      assert_response :forbidden
    end

    test 'SBK ergänzt eine RSK-Rolle im eigenen Verbund' do
      target = create(:user, :assigner_scoped, game_operation_id: @lv.id)
      login(@sbk_lv)

      post "/api/v2/admin/users/#{target.id}/add_role", params: {
        user_group_id: 3, game_operation_id: @lv.id
      }
      assert_response :success

      assert_equal [3, 7], target.reload.permissions.map { |p| p['user_group_id'].to_i }.sort
    end

    # --- Rollen entziehen --------------------------------------------------

    test 'RSK entzieht eine Ansetzer-Rolle im eigenen Verbund' do
      target = create(:user, permissions: [
        { 'user_group_id' => 3, 'game_operation_id' => @lv.id.to_s },
        { 'user_group_id' => 7, 'game_operation_id' => @lv.id.to_s }
      ])
      login(@rsk_lv)

      delete "/api/v2/admin/users/#{target.id}/remove_role", params: {
        user_group_id: 7, game_operation_id: @lv.id
      }
      assert_response :success

      assert_equal([3], target.reload.permissions.map { |p| p['user_group_id'].to_i })
    end

    test 'RSK entzieht keine SBK-Rolle' do
      target = create(:user, permissions: [
        { 'user_group_id' => 2, 'game_operation_id' => @lv.id.to_s },
        { 'user_group_id' => 3, 'game_operation_id' => @lv.id.to_s }
      ])
      login(@rsk_lv)

      delete "/api/v2/admin/users/#{target.id}/remove_role", params: {
        user_group_id: 2, game_operation_id: @lv.id
      }
      assert_response :forbidden
      assert_equal 2, target.reload.permissions.length
    end

    # --- Schiedsrichter-Rolle ----------------------------------------------

    test 'Schiedsrichter-Konto bekommt keine weitere Rolle' do
      referee_user = create(:user, permissions: [{ 'user_group_id' => 6 }])
      admin = create(:user, :admin)
      login(admin)

      post "/api/v2/admin/users/#{referee_user.id}/add_role", params: {
        user_group_id: 7, game_operation_id: @lv.id
      }
      assert_response :unprocessable_entity
      assert_equal([6], referee_user.reload.permissions.map { |p| p['user_group_id'].to_i })
    end

    test 'Schiedsrichter-Rolle laesst sich nicht zu einem Verwaltungskonto ergaenzen' do
      user = create(:user, :rsk_scoped, game_operation_id: @lv.id)

      user.permissions += [{ 'user_group_id' => 6 }]

      refute user.valid?
      assert_includes user.errors[:permissions].join,
                      'Schiedsrichter-Rolle kann nicht mit anderen Rollen kombiniert werden'
    end

    test 'Bestandskonto mit kombinierter Schiedsrichter-Rolle bleibt speicherbar' do
      user = create(:user, :rsk_scoped, game_operation_id: @lv.id)
      # Verletzung an der Validierung vorbei anlegen, wie sie im Bestand
      # vorkommen kann: Der Login (last_login_at) darf daran nicht scheitern.
      user.update_columns(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => @lv.id.to_s },
                                        { 'user_group_id' => 6 }])

      assert user.reload.update(last_login_at: Time.current)
    end

    test 'kombinierte Schiedsrichter-Rolle laesst sich per Rollen-Entzug reparieren' do
      user = create(:user, :rsk_scoped, game_operation_id: @lv.id)
      user.update_columns(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => @lv.id.to_s },
                                        { 'user_group_id' => 6 }])
      admin = create(:user, :admin)
      login(admin)

      delete "/api/v2/admin/users/#{user.id}/remove_role", params: { user_group_id: 6 }
      assert_response :success
      assert_equal([3], user.reload.permissions.map { |p| p['user_group_id'].to_i })
    end

    # --- Sichtbarkeit -----------------------------------------------------

    test 'RSK sieht die Benutzerverwaltung und darf Rollen verwalten' do
      items = @rsk_lv.permissions_items

      assert items[:menu_item_user_admin]
      assert items[:manage_user_roles]
      assert items[:menu_item_user_create]
      assert items[:assign_role_rsk]
      assert items[:assign_role_ansetzer]
      refute items[:assign_role_sbk]
      refute items[:assign_role_vm]
      refute items[:assign_role_admin]
    end

    test 'SBK darf SBK, RSK, Ansetzer, VM und TM vergeben, aber nicht Admin' do
      items = @sbk_lv.permissions_items

      assert items[:assign_role_sbk]
      assert items[:assign_role_rsk]
      assert items[:assign_role_ansetzer]
      assert items[:assign_role_vm]
      assert items[:assign_role_tm]
      refute items[:assign_role_admin]
    end

    test 'Ansetzer verwaltet keine Benutzer' do
      ansetzer = create(:user, :assigner_scoped, game_operation_id: @lv.id)
      login(ansetzer)

      get '/api/v2/admin/users'
      assert_response :forbidden
    end

    private

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end
  end
end
