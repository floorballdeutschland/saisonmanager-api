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
    assert items[:menu_item_state_association_admin]
    assert items[:menu_item_api_key_admin]
    assert items[:menu_item_season_admin]
    assert items[:admin], 'Admin muss den expliziten admin-Boolean für das Frontend bekommen'
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
    assert_not items[:admin], 'VM darf den admin-Boolean nicht bekommen'
    assert_not items[:login_blocked]
  end

  test 'permissions_items: RSK bekommt Schiri-Admin, aber KEINE Ansetzungen' do
    u = build_user(permissions: [{ 'user_group_id' => 3, 'game_operation_id' => 1 }])
    items = u.permissions_items

    assert items[:menu_item_referee_admin]
    # Ansetzungen sind eine eigene Rolle (Ansetzer) – die reine RSK sieht sie nicht.
    assert_not items[:menu_item_referee_assignments]
    assert_not items[:menu_item_league_admin]
    # RSK darf seinen Landesverband NICHT verwalten (nur SBK).
    assert_not items[:menu_item_state_association_sbk]
  end

  test 'permissions_items: Ansetzer bekommt Ansetzungen und Schiri-Admin' do
    sa = create(:state_association, referee_assignment_enabled: true)
    go = create(:game_operation, state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 7, 'game_operation_id' => go.id }])
    items = u.permissions_items

    assert items[:menu_item_referee_assignments]
    assert items[:menu_item_referee_availability]
    # Ansetzer braucht (eingeschränkten) Lesezugriff auf die Schiedsrichterdaten.
    assert items[:menu_item_referee_admin]
    assert items[:referee_edit_restricted]
    assert_not items[:referee_can_create]
    assert_not items[:menu_item_league_admin]
  end

  test 'permissions_items: Ansetzer ohne freigeschalteten Landesverband sieht keine Ansetzungen' do
    sa = create(:state_association, referee_assignment_enabled: false)
    go = create(:game_operation, state_association: sa)
    u = build_user(permissions: [{ 'user_group_id' => 7, 'game_operation_id' => go.id }])
    items = u.permissions_items

    assert_not items[:menu_item_referee_assignments]
    assert_not items[:menu_item_referee_availability]
    # Lesezugriff auf die Schiedsrichterdaten bleibt davon unberührt.
    assert items[:menu_item_referee_admin]
  end

  test 'permission_hash: Ansetzer mit allen GOs ergibt [0]' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 7, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_equal [0], u.permission_hash[:ansetzer]
  end

  test 'permission_hash: Ansetzer mit spezifischen GOs ergibt sortiertes Array' do
    u = build_user(permissions: [
      { 'user_group_id' => 7, 'game_operation_id' => 5 },
      { 'user_group_id' => 7, 'game_operation_id' => 2 }
    ])
    assert_equal [2, 5], u.permission_hash[:ansetzer]
  end

  test 'permissions_items: kombinierte RSK+Ansetzer-Rolle bekommt beide Funktionen' do
    sa = create(:state_association, referee_assignment_enabled: true)
    go = create(:game_operation, state_association: sa)
    u = build_user(permissions: [
      { 'user_group_id' => 3, 'game_operation_id' => go.id },
      { 'user_group_id' => 7, 'game_operation_id' => go.id }
    ])
    items = u.permissions_items

    assert items[:menu_item_referee_admin]
    assert items[:menu_item_referee_assignments]
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

  # --- Phase 2 Extensions ---

  test 'club_ids: VM-Nutzer gibt permission_hash[:vm] zurück' do
    u = build_user(permissions: [
      { 'user_group_id' => 4, 'club_id' => 15 },
      { 'user_group_id' => 4, 'club_id' => 3 }
    ])
    assert_equal u.permission_hash[:vm], u.club_ids
    assert_equal [3, 15], u.club_ids
  end

  test 'club_ids: Admin gibt nil/leeres Ergebnis zurück (kein :vm im Hash)' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_nil u.club_ids
  end

  test 'club_ids: SBK gibt nil/leeres Ergebnis zurück (kein :vm im Hash)' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 2, 'game_operation_id' => go } }
    u = build_user(permissions: perms)
    assert_nil u.club_ids
  end

  test 'Club.admin_user_clubs: globaler Admin erhält Einträge für alle GameOperations' do
    perms = ALL_GO.map { |go| { 'user_group_id' => 1, 'game_operation_id' => go } }
    admin = build_user(permissions: perms)
    # global_access path: fetches all GameOperations
    result = Club.admin_user_clubs(admin)
    expected_go_count = GameOperation.count
    assert_equal expected_go_count, result.size
  end

  test 'permission_hash: deterministisch – gleicher Nutzer ergibt immer denselben Hash' do
    u = build_user(permissions: [
      { 'user_group_id' => 1, 'game_operation_id' => 3 },
      { 'user_group_id' => 4, 'club_id' => 7 }
    ])
    first_call  = u.permission_hash
    second_call = u.permission_hash
    assert_equal first_call, second_call
  end

  test 'permissions_items: Admin darf Lizenzstatus auf TRANSFER setzen' do
    u = build_user(permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }])
    assert u.permissions_items[:player_set_license_to_transfer]
  end

  test 'permissions_items: früher hartcodierter Sonder-Nutzer ohne Admin-Rechte darf NICHT mehr Lizenzstatus auf TRANSFER setzen' do
    # Das frühere special_user-Sonderrecht (hartcodierte Nutzernamen) wurde
    # entfernt; ohne Admin-Rolle gibt es das Recht nicht mehr.
    u = User.create!(
      user_name: 'jho_admin',
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 4, 'club_id' => 1 }],
      teams: []
    )
    assert_not u.permissions_items[:player_set_license_to_transfer]
  end

  test 'permissions_items: normaler VM-Nutzer (kein Admin) darf NICHT Lizenzstatus auf TRANSFER setzen' do
    u = build_user(permissions: [{ 'user_group_id' => 4, 'club_id' => 99 }])
    assert_not u.permissions_items[:player_set_license_to_transfer]
  end
end
