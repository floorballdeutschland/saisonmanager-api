require 'test_helper'

# Tests für die zeitlich begrenzten Spielersperren aus Issue #508:
# Ebene 1 (Lizenzaussetzung einer Team-Lizenz) und Ebene 2 (Beantragungssperre).
class PlayerSuspensionTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
    league = create(:league, :current_season)
    @team_a = create(:team, league: league)
    @team_b = create(:team, league: league)
  end

  def current_status(player, team)
    license = player.licenses.find { |l| l['team_id'].to_i == team.id }
    license['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i
  end

  test 'Ebene 1: suspend! mit team_id setzt nur diese Lizenz auf gesperrt' do
    player = create(:player, with_licenses: [
      { team: @team_a, status: License::APPROVED },
      { team: @team_b, status: License::APPROVED }
    ])

    suspension = player.suspend!(team_id: @team_a.id, valid_until: Date.current + 7, user_id: @user.id)

    assert_equal License::SUSPENDED, current_status(player, @team_a)
    assert_equal License::APPROVED, current_status(player, @team_b)
    assert_equal 1, suspension.affected_licenses.size
    refute suspension.player_wide?
  end

  test 'Ebene 2: suspend! ohne team_id sperrt alle aktiven Lizenzen und blockiert Anträge' do
    player = create(:player, with_licenses: [
      { team: @team_a, status: License::APPROVED },
      { team: @team_b, status: License::REQUESTED }
    ])

    player.suspend!(valid_until: Date.current + 365, user_id: @user.id, reason: 'NADA-Sperre')

    assert_equal License::SUSPENDED, current_status(player, @team_a)
    assert_equal License::SUSPENDED, current_status(player, @team_b)
    assert player.application_blocked?
  end

  test 'Beantragungssperre ist auch ohne aktive Lizenzen wirksam' do
    player = create(:player)

    player.suspend!(valid_until: Date.current + 30, user_id: @user.id)

    assert player.application_blocked?
  end

  test 'lift_suspension! reaktiviert Lizenzen auf vorherigen Status' do
    player = create(:player, with_licenses: [
      { team: @team_a, status: License::APPROVED },
      { team: @team_b, status: License::REQUESTED }
    ])
    suspension = player.suspend!(valid_until: Date.current + 30, user_id: @user.id)

    player.lift_suspension!(suspension, user_id: @user.id)

    assert_equal License::APPROVED, current_status(player, @team_a)
    assert_equal License::REQUESTED, current_status(player, @team_b)
    refute suspension.reload.active?
    refute player.application_blocked?
  end

  test 'application_blocked? hebt fällige Sperren lazy auf und reaktiviert Lizenzen' do
    player = create(:player, with_licenses: [
      { team: @team_a, status: License::APPROVED }
    ])
    suspension = player.suspend!(valid_until: Date.current + 5, user_id: @user.id)
    # Sperre rückwirkend fällig machen.
    suspension.update!(valid_from: Date.current - 10, valid_until: Date.current - 1)

    refute player.application_blocked?
    assert_equal License::APPROVED, current_status(player, @team_a)
    refute suspension.reload.active?
  end

  test 'suspended_for_team? erkennt aktive Ebene-1-Sperre nur für das betroffene Team' do
    player = create(:player, with_licenses: [
      { team: @team_a, status: License::APPROVED },
      { team: @team_b, status: License::APPROVED }
    ])
    player.suspend!(team_id: @team_a.id, valid_until: Date.current + 7, user_id: @user.id)

    assert player.suspended_for_team?(@team_a.id)
    refute player.suspended_for_team?(@team_b.id)
  end

  test 'lift lässt manuell geänderte Lizenzen unangetastet' do
    player = create(:player, with_licenses: [
      { team: @team_a, status: License::APPROVED }
    ])
    suspension = player.suspend!(valid_until: Date.current + 30, user_id: @user.id)

    # Nach der Sperre wird die Lizenz manuell gelöscht.
    license = player.licenses.find { |l| l['team_id'].to_i == @team_a.id }
    license['history'] << {
      'license_status_id' => License::DELETED,
      'created_by' => @user.id,
      'created_at' => Time.now
    }
    player.save!(validate: false)

    player.lift_suspension!(suspension, user_id: @user.id)

    assert_equal License::DELETED, current_status(player, @team_a)
  end
end
