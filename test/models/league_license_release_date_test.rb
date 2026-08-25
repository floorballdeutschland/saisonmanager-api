require 'test_helper'

# Freigabedatum in den Lizenzlisten (League#licenses / League.licenses_for).
#
# Fachlicher Hintergrund: Die Lizenzordnung setzt die Freigabefrist für ein
# DM-Team bzw. den FD-Spielbetrieb auf den 15.01., die SPO die Beantragungsfrist
# auf den 28.02. Vereine, Ausrichter und SBK sollen beides in der Lizenzliste
# ablesen können, statt es je Spieler nachzufragen. Der Saisonmanager prüft die
# Fristen NICHT, er zeigt nur die Daten.
class LeagueLicenseReleaseDateTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @league = create(:league, :current_season)
    @club   = create(:club)
    @team   = create(:team, league: @league, club: @club)
    @former = create(:club)
    @admin  = create(:user, :admin)
  end

  def player_with_license(team: @team, status: License::APPROVED)
    create(:player, with_licenses: [{ team: team, status: status }])
  end

  def release(player, to: @club, status: 'approved', season: 18, approved_at: Time.zone.parse('2026-01-10 09:00'))
    TransferRequest.create!(
      player: player,
      requesting_club: to,
      former_club: @former,
      season_id: season,
      status: status,
      request_type: 'release',
      created_by: @admin.id,
      lv_approved_at: status == 'approved' ? approved_at : nil
    )
  end

  def team_license_for(player, league: @league)
    item = league.licenses.first
    item[:players].find { |p| p[:id] == player.id }&.dig(:team_license)
  end

  test 'genehmigte Freigabe für den Verein der Mannschaft liefert das Datum' do
    player = player_with_license
    release(player)

    assert_equal Time.zone.parse('2026-01-10 09:00'), team_license_for(player)[:released_at]
  end

  test 'ohne Freigabe bleibt das Feld leer' do
    player = player_with_license

    assert_nil team_license_for(player)[:released_at]
  end

  test 'noch nicht genehmigte Freigabe zählt nicht' do
    player = player_with_license
    release(player, status: 'pending_lv')

    assert_nil team_license_for(player)[:released_at]
  end

  test 'zurückgezogene Freigabe zählt nicht' do
    player = player_with_license
    tr = release(player)
    tr.update!(status: 'revoked', revoked_by: @admin.id, revoked_at: Time.current,
               revocation_reason: 'Test')

    assert_nil team_license_for(player)[:released_at]
  end

  test 'ein Transfer ist keine Freigabe' do
    player = player_with_license
    release(player).update!(request_type: 'transfer')

    assert_nil team_license_for(player)[:released_at]
  end

  test 'Freigabe an einen anderen Verein zählt nicht' do
    player = player_with_license
    release(player, to: create(:club))

    assert_nil team_license_for(player)[:released_at]
  end

  test 'Freigabe aus einer anderen Saison zählt nicht' do
    player = player_with_license
    release(player, season: 17)

    assert_nil team_license_for(player)[:released_at]
  end

  test 'bei mehreren Freigaben an denselben Verein zählt die jüngste' do
    player = player_with_license
    release(player, approved_at: Time.zone.parse('2026-01-05 09:00'))
    release(player, approved_at: Time.zone.parse('2026-02-01 09:00'))

    assert_equal Time.zone.parse('2026-02-01 09:00'), team_license_for(player)[:released_at]
  end

  test 'Spielgemeinschaft: Freigabe an einen der beteiligten Vereine genügt' do
    partner = create(:club)
    @team.update!(syndicate: true, syndicate_clubs: [partner.id])
    player = player_with_license
    release(player, to: partner)

    assert_equal Time.zone.parse('2026-01-10 09:00'), team_license_for(player)[:released_at]
  end

  test 'Beantragungsdatum bleibt nach der Erteilung stehen' do
    player = create(:player, with_licenses: [{ team: @team, status: License::REQUESTED,
                                               created_at: 3.days.ago.iso8601 }])
    player.licenses.first['history'] << {
      'license_status_id' => License::APPROVED,
      'created_by' => @admin.id,
      'created_at' => 1.day.ago.iso8601
    }
    player.save!

    team_license = team_license_for(player)

    assert_not_nil team_license[:requested_at], 'beantragt am bleibt sichtbar'
    assert_not_nil team_license[:approved_at], 'erteilt am steht daneben'
    assert_operator team_license[:requested_at], :<, team_license[:approved_at]
  end
end
