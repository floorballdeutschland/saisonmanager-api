require 'test_helper'

# Die Schreib- und Anzeigewege, die den Lizenzstatus aus dem letzten
# Array-Element lasen statt aus dem juengsten Eintrag (#725).
#
# Unsortiert steht die History real dort, wo Eintraege mit verschiedenem Offset
# als Text sortiert wurden, vor allem nach Spieler-Merges zwischen #71 und #570.
# Die Testhistory bildet genau das ab: Geloescht um 17:59 UTC (als
# `19:59+02:00` gespeichert), wieder erteilt um 18:25 UTC. Als Text steht die
# Loeschung hinten, der letzte Eintrag ist also der aeltere.
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

  def offset_disordered_history
    [entry(License::REQUESTED, '2026-08-01T10:00:00+00:00'),
     entry(License::APPROVED, '2026-08-03T18:25:00+00:00'),
     entry(License::DELETED, '2026-08-03T19:59:00+02:00')]
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

  test 'invalidate_licenses! erkennt die erteilte Lizenz trotz Offset-Unordnung' do
    player = player_with_license(@former_team, offset_disordered_history)

    transfer_request(player, 'transfer').send(:invalidate_licenses!)

    assert_equal License::TRANSFER, current_status(player)
  end

  test 'invalidate_release_licenses! erkennt die erteilte Lizenz trotz Offset-Unordnung' do
    player = player_with_license(@requesting_team, offset_disordered_history)

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

  test '_void_memberships_and_licenses! loescht die erteilte Lizenz trotz Offset-Unordnung' do
    player = player_with_license(@former_team, offset_disordered_history)

    player._void_memberships_and_licenses!(@user.id, reason: 'Dublette')
    player.save!(validate: false)

    assert_equal License::DELETED, current_status(player)
    assert_equal 4, player.licenses.first['history'].size
  end

  test 'select_license nimmt den Status aus dem juengsten Eintrag' do
    player = player_with_license(@former_team, offset_disordered_history)

    selected = player.send(:select_license, player.licenses.map(&:dup))

    assert_equal License::APPROVED, selected['license_status_id']
  end

  # Begruendet den Basisstatus in den Schreibwegen: Der Transfer setzt auch die
  # gesperrte Lizenz auf Transfer, und das Ende der Sperre holt sie danach
  # nicht zurueck, weil lift_suspension! nur auf einen obersten Sperr-Eintrag
  # reagiert.
  test 'nach Sperre, Transfer und Aufhebung der Sperre bleibt die Lizenz auf Transfer' do
    player = player_with_license(@former_team, [entry(License::APPROVED, '2026-08-03T10:00:00+02:00')])
    suspension = player.suspend!(user_id: @user.id, reason: 'Test', games_total: 2)

    transfer_request(player.reload, 'transfer').send(:invalidate_licenses!)
    player.reload.lift_suspension!(suspension.reload, user_id: @user.id)

    statuses = player.reload.licenses.first['history'].map { |h| h['license_status_id'].to_i }
    assert_equal [License::APPROVED, License::SUSPENDED, License::TRANSFER], statuses
    assert_equal License::TRANSFER, current_status(player)
  end

  # Die Partnerlogik der GF-Erst-/Zweitlizenz, die das Frontend in der
  # Spielermaske spiegelt.
  test 'gf_competition_licenses erkennt die aktive Partnerlizenz trotz Offset-Unordnung' do
    league = create(:league, field_size: 'GF', age_group: 'Erwachsene', female: false)
    own_team = create(:team, club: @former_club, league: league)
    partner_team = create(:team, club: @requesting_club, league: league)
    licenses = [
      { 'id' => 'a', 'team_id' => own_team.id, 'season_id' => '18',
        'history' => [entry(License::APPROVED, '2026-08-01T10:00:00+00:00')] },
      { 'id' => 'b', 'team_id' => partner_team.id, 'season_id' => '18', 'history' => offset_disordered_history }
    ]
    player = create(:player, licenses: licenses)

    partner_ids = player.gf_competition_licenses(player.licenses.first, league).map { |l| l['id'] }

    assert_equal ['b'], partner_ids
  end
end
