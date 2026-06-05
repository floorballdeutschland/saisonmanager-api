require 'test_helper'

# Invarianten für das Permission-System.
# Prüft, dass permission_hash deterministisch ist, Admin-Zugriff korrekt
# aufgelöst wird und Permission-Änderungen keine Lizenzen beeinflussen.
class PermissionConsistencyTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club,
                   game_operations_hash: [{ 'game_operation_id' => @game_operation.id,
                                            'home_game_operation' => true }])
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team   = create(:team, league: @league, club: @club)
  end

  test 'permission_hash ist deterministisch (gleicher User → gleicher Output)' do
    user = create(:user, :admin)

    result1 = user.permission_hash
    result2 = user.permission_hash

    assert_equal result1, result2,
                 'permission_hash muss für denselben User denselben Wert liefern'
  end

  test 'Admin-User hat globalen Zugriff in permission_hash' do
    admin = create(:user, :admin)
    ph = admin.permission_hash

    assert ph[:admin].present?, 'Admin muss :admin-Schlüssel in permission_hash haben'
    assert ph[:admin].include?(0), 'Globaler Admin muss game_operation_id 0 haben'
  end

  test 'SBK-User mit game_operation_id hat keinen globalen Zugriff' do
    sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    ph = sbk.permission_hash

    refute ph[:admin].to_a.include?(0), 'Scoped SBK darf keinen globalen Admin-Zugriff haben'
    assert ph[:sbk].present?, 'SBK-User muss :sbk-Schlüssel in permission_hash haben'
  end

  test 'VM-User hat Zugriff auf seinen Club in permission_hash' do
    vm = create(:user, :vm, club_id: @club.id)
    ph = vm.permission_hash

    assert ph[:vm].present?, 'VM-User muss :vm-Schlüssel in permission_hash haben'
    assert_includes ph[:vm], @club.id,
                    "VM-User muss Club #{@club.id} in seinem VM-Zugriff haben"
  end

  test 'Club.admin_user_clubs ist nicht leer für globalen Admin' do
    admin = create(:user, :admin)

    clubs = Club.admin_user_clubs(admin)

    assert clubs.present?,
           'Club.admin_user_clubs darf für einen Admin nicht leer sein (globaler Zugriff)'
  end

  test 'Permission-Änderung am User ändert keine Lizenzen des Players' do
    player = create(:player, with_licenses: [{ team: @team, status: License::APPROVED }])
    user   = create(:user, :admin)
    licenses_before = player.licenses.deep_dup

    user.update!(permissions: [{ 'user_group_id' => 2, 'game_operation_id' => 0 }])

    player.reload
    assert_equal licenses_before.size, player.licenses.size,
                 'Permission-Änderung am User darf Lizenzen nicht beeinflussen'
    assert_equal licenses_before.first['history'].size,
                 player.licenses.first['history'].size,
                 'License-History darf durch Permission-Änderung nicht verändert werden'
  end

  test 'User ohne Permissions hat leeren permission_hash' do
    user = create(:user)  # keine Permissions

    ph = user.permission_hash

    assert ph[:admin].blank?, 'User ohne Admin-Permission darf kein :admin haben'
    assert ph[:sbk].blank?,   'User ohne SBK-Permission darf kein :sbk haben'
    assert ph[:vm].blank?,    'User ohne VM-Permission darf kein :vm haben'
  end
end
