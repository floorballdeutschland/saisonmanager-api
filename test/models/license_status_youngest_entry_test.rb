require 'test_helper'

# Die Schreib- und Anzeigewege, die den Lizenzstatus aus dem letzten
# Array-Element lasen statt aus dem juengsten Eintrag (#725).
#
# Unsortiert wird die History real durch den Spieler-Merge: Er haengt die
# History der Dublette hinter die des Masters. Das letzte Element ist dann der
# juengste Eintrag der Dublette, hier ein alter `geloescht`, waehrend die
# Lizenz seit dem Merge laengst wieder `erteilt` ist.
class LicenseStatusYoungestEntryTest < ActiveSupport::TestCase
  def setup
    @state_association = create(:state_association)
    @requesting_club   = Club.create!(name: 'Neuer Verein', short_name: 'NV',
                                      state_association_id: @state_association.id)
    @former_club       = Club.create!(name: 'Alter Verein', short_name: 'AV',
                                      state_association_id: @state_association.id)
    @user              = create(:user, :admin)
    create(:setting, current_season_id: '18')

    @former_team     = create(:team, club: @former_club)
    @requesting_team = create(:team, club: @requesting_club)
  end

  def entry(status, created_at)
    { 'license_status_id' => status, 'created_at' => created_at }
  end

  # Master erteilt 2026, dahinter die Dublette mit ihrem alten Loescheintrag.
  def merged_history
    [entry(License::REQUESTED, '2026-08-01T10:00:00+02:00'),
     entry(License::APPROVED, '2026-08-03T10:00:00+02:00'),
     entry(License::REQUESTED, '2024-08-01T10:00:00+02:00'),
     entry(License::DELETED, '2025-06-01T10:00:00+02:00')]
  end

  def player_with_license(team, history)
    create(:player,
           clubs: [{ 'club_id' => @former_club.id, 'home_club' => true, 'valid_until' => nil }],
           licenses: [{ 'id' => SecureRandom.uuid, 'team_id' => team.id, 'history' => history }])
  end

  def transfer_request(player, request_type)
    TransferRequest.new(player: player, requesting_club: @requesting_club, former_club: @former_club,
                        created_by: @user.id, season_id: 18, request_type: request_type)
  end

  def current_status(player)
    LicenseEffectiveStatus.current_status_id(player.reload.licenses.first)
  end

  test 'invalidate_licenses! erkennt die erteilte Lizenz hinter dem Merge-Anhang' do
    player = player_with_license(@former_team, merged_history)

    transfer_request(player, 'transfer').send(:invalidate_licenses!)

    assert_equal License::TRANSFER, current_status(player)
  end

  test 'invalidate_release_licenses! erkennt die erteilte Lizenz hinter dem Merge-Anhang' do
    player = player_with_license(@requesting_team, merged_history)

    transfer_request(player, 'release').send(:invalidate_release_licenses!, @user.id)

    assert_equal License::WITHDRAWN, current_status(player)
  end

  # Eine gesperrte Lizenz blieb bisher stehen und kam mit dem Ende der Sperre
  # ueber lift_suspension! als `erteilt` zurueck, beim alten Verein.
  test 'invalidate_licenses! setzt auch eine gesperrte Lizenz auf Transfer' do
    player = player_with_license(@former_team,
                                 [entry(License::APPROVED, '2026-08-03T10:00:00+02:00'),
                                  entry(License::SUSPENDED, '2026-09-01T10:00:00+02:00')])

    transfer_request(player, 'transfer').send(:invalidate_licenses!)

    assert_equal License::TRANSFER, current_status(player)
  end

  test 'eine bereits zurueckgezogene Lizenz bekommt keinen weiteren Eintrag' do
    player = player_with_license(@former_team,
                                 [entry(License::WITHDRAWN, '2026-09-01T10:00:00+02:00'),
                                  entry(License::APPROVED, '2026-08-03T10:00:00+02:00')])

    transfer_request(player, 'transfer').send(:invalidate_licenses!)

    assert_equal 2, player.reload.licenses.first['history'].size
  end

  test '_void_memberships_and_licenses! loescht die erteilte Lizenz hinter dem Merge-Anhang' do
    player = player_with_license(@former_team, merged_history)

    player._void_memberships_and_licenses!(@user.id, reason: 'Dublette')
    player.save!(validate: false)

    assert_equal License::DELETED, current_status(player)
    assert_equal 5, player.licenses.first['history'].size
  end

  test 'select_license nimmt den Status aus dem juengsten Eintrag' do
    player = player_with_license(@former_team, merged_history)

    selected = player.send(:select_license, player.licenses.map(&:dup))

    assert_equal License::APPROVED, selected['license_status_id']
  end
end
