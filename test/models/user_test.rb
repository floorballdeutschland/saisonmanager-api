require 'test_helper'

class UserTest < ActiveSupport::TestCase
  ALL_GO = [1, 2, 3, 4, 5, 6, 8, 9, 10, 11].freeze

  def build_user(permissions:, teams: [])
    User.create!(
      user_name: "testuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: permissions,
      teams: teams
    )
  end

  # ---------------------------------------------------------------------------
  # permission_hash
  # ---------------------------------------------------------------------------

  test 'permission_hash: leere Permissions ergibt leeren Hash' do
    u = build_user(permissions: [])
    assert_equal({}, u.permission_hash)
  end

  test 'permission_hash: Admin mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:admin]
    assert_nil u.permission_hash[:sbk]
    assert_nil u.permission_hash[:vm]
  end

  test 'permission_hash: Admin mit einzelnem GO ergibt spezifische ID' do
    u = build_user(permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 2 }])
    assert_equal [2], u.permission_hash[:admin]
  end

  test 'permission_hash: SBK mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 2, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:sbk]
    assert_nil u.permission_hash[:admin]
  end

  test 'permission_hash: SBK für nationales GO (kein state_association_id) ergibt [0]' do
    national_go = GameOperation.create!(name: 'FD Test', short_name: 'FDT', path: 'fd-test')
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => national_go.id }])
    assert_equal [0], u.permission_hash[:sbk]
  end

  test 'permission_hash: RSK für nationales GO (kein state_association_id) ergibt [0]' do
    national_go = GameOperation.create!(name: 'FD RSK Test', short_name: 'FDRT', path: 'fd-rsk-test')
    u = build_user(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => national_go.id }])
    assert_equal [0], u.permission_hash[:rsk]
  end

  test 'permission_hash: SBK für regionales GO (hat state_association_id) behält spezifische ID' do
    sa = StateAssociation.create!(name: 'Test LV', short_name: 'TLV')
    regional_go = GameOperation.create!(name: 'SBK Test', short_name: 'SBT', path: 'sbk-test', state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => regional_go.id }])
    assert_equal [regional_go.id], u.permission_hash[:sbk]
  end

  test 'permission_hash: VM mit club_id ergibt club_ids-Array' do
    u = build_user(permissions: [
      { 'user_group_id' => 4, 'club_id' => 42 },
      { 'user_group_id' => 4, 'club_id' => 7 }
    ])
    assert_equal [7, 42], u.permission_hash[:vm]
  end

  test 'permission_hash: RSK mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 3, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:rsk]
  end

  test 'permission_hash: RSK mit spezifischen GOs ergibt sortiertes Array' do
    u = build_user(permissions: [
      { 'user_group_id' => 3, 'game_operation_id' => 5 },
      { 'user_group_id' => 3, 'game_operation_id' => 2 }
    ])
    assert_equal [2, 5], u.permission_hash[:rsk]
  end

  test 'permission_hash: Schiri-Rolle erzeugt keinen Hash-Eintrag' do
    u = build_user(permissions: [{ 'user_group_id' => 6 }])
    assert_equal({}, u.permission_hash)
  end

  test 'permission_hash: Mehrere Rollen gleichzeitig werden korrekt getrennt' do
    u = build_user(permissions: [
      { 'user_group_id' => 1, 'game_operation_id' => 1 },
      { 'user_group_id' => 4, 'club_id' => 10 }
    ])
    ph = u.permission_hash
    assert_equal [1], ph[:admin]
    assert_equal [10], ph[:vm]
    assert_nil ph[:sbk]
  end

  # ---------------------------------------------------------------------------
  # permissions_items
  # ---------------------------------------------------------------------------

  test 'permissions_items: Admin bekommt alle admin-gebundenen Menüeinträge' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    items = u.permissions_items

    assert items[:menu_item_league_admin]
    assert items[:menu_item_referee_admin]
    assert items[:menu_item_online_test_admin]
    assert items[:menu_item_state_association_admin]
    assert items[:menu_item_api_key_admin]
    assert items[:menu_item_season_admin]
    assert_not items[:login_blocked]
  end

  test 'permissions_items: VM bekommt vm-spezifische Einträge, nicht admin-Einträge' do
    u = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => 5 }])
    items = u.permissions_items

    assert items[:menu_item_referee_vm]
    assert items[:menu_item_player_admin_vm]
    assert items[:menu_item_user_vm]
    assert_not items[:menu_item_league_admin]
    assert_not items[:menu_item_state_association_admin]
    assert_not items[:menu_item_referee_admin]
    assert_not items[:login_blocked]
  end

  test 'permissions_items: RSK bekommt Schiri-Admin und Online-Test-Admin' do
    u = build_user(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 1 }])
    items = u.permissions_items

    assert items[:menu_item_referee_admin]
    assert items[:menu_item_online_test_admin]
    assert items[:menu_item_referee_assignments]
    assert_not items[:menu_item_league_admin]
    # RSK darf seinen Landesverband NICHT verwalten (nur SBK).
    assert_not items[:menu_item_state_association_sbk]
  end

  test 'permissions_items: regionaler SBK bekommt den eigenen LV-Verwaltungseintrag' do
    sa = StateAssociation.create!(name: 'SBK-LV Test', short_name: 'SLT')
    regional_go = GameOperation.create!(name: 'SBK Region', short_name: 'SBR', path: 'sbk-region',
                                        state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => regional_go.id }])
    items = u.permissions_items

    assert items[:menu_item_state_association_sbk]
    assert_not items[:menu_item_state_association_admin]
  end

  test 'permissions_items: regionaler RSK bekommt KEINEN LV-Verwaltungseintrag' do
    sa = StateAssociation.create!(name: 'RSK-LV Test', short_name: 'RLT')
    regional_go = GameOperation.create!(name: 'RSK Region', short_name: 'RSR', path: 'rsk-region',
                                        state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => regional_go.id }])
    items = u.permissions_items

    assert_not items[:menu_item_state_association_sbk]
    assert_not items[:menu_item_state_association_admin]
  end

  test 'permissions_items: Schiri-only bekommt nur Profil-Zugriff' do
    u = build_user(permissions: [{ 'user_group_id' => 6 }])
    items = u.permissions_items

    assert items[:menu_item_referee_profile]
    assert items[:show_page_referee_profile]
    assert_not items[:login_blocked]
    assert_nil items[:menu_item_league_admin]
  end

  test 'permissions_items: TM ohne Teams in aktueller Saison ist login_blocked' do
    u = build_user(
      permissions: [{ 'user_group_id' => 5 }],
      teams: []
    )
    items = u.permissions_items

    assert items[:login_blocked]
  end
end
