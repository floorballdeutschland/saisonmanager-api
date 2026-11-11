require 'test_helper'

# Abrechnender Verein fuer Lizenzen in Spielgemeinschaften (SG).
#
# Regel (festgelegt 11.11.2026):
#   1. der Heimatverein des Spielers, wenn er Verein der SG ist,
#   2. sonst der SG-Verein, bei dem der Spieler eine Freigabe hat.
# Nicht der eingetragene Verein des SG-Teams (`teams.club_id`).
#
# Bis hierher pruefte `Player#create_license_hash` den nicht vorhandenen
# Schluessel `p[:license_hash_id]`, Regel 1 griff also nie. Hatte der Spieler
# zusaetzlich einen gueltigen Eintrag beim SG-Partner, etwa eine Freigabe, stand
# die Lizenz beim Partner, der zuerst aus der Datenbank kam (Saison 2026/27:
# 13 Lizenzen).
class LicenseFeeCalculationSyndicateTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
    @haupt = create(:club, name: 'Hauptverein')
    @partner = create(:club, name: 'Partnerverein')
    @fremd = create(:club, name: 'Fremdverein')
    @league_rl = create(:league, :current_season, league_class_id: 'rl')
    @league_vl = create(:league, :current_season, league_class_id: 'vl')
    @sg_rl = create(:team, league: @league_rl, club: @haupt, syndicate: true, syndicate_clubs: [@partner.id])
    @sg_vl = create(:team, league: @league_vl, club: @haupt, syndicate: true, syndicate_clubs: [@partner.id])
  end

  def eintrag(club, heimat)
    { 'club_id' => club.id, 'home_club' => heimat, 'valid_from' => '2020-01-01', 'valid_until' => nil }
  end

  def lizenz(id, team)
    { 'id' => id, 'team_id' => team.id, 'season_id' => '18',
      'league_class_id' => team.league.league_class_id,
      'history' => [{ 'license_status_id' => License::APPROVED, 'created_at' => 5.days.ago.iso8601 }] }
  end

  def spieler(*vereine, teams: [@sg_rl])
    create(:player, clubs: vereine,
                    licenses: teams.each_with_index.map { |t, i| lizenz("l#{i}", t) })
  end

  def abgerechnet_bei(player)
    calc = LicenseFeeCalculation.start_calculation(@user.id, '18')
    main = calc.interal_hash.compact.select { |r| r[:id] == player.id && r[:license_id].present? }
    other = calc.other_hash.select { |r| r[:id] == player.id }
    (main + other).to_h { |r| [r[:license_id], r[:license_club]] }
  end

  test 'Heimatverein in der SG mit Freigabe beim Hauptverein: Heimatverein' do
    p = spieler(eintrag(@partner, true), eintrag(@haupt, false))

    assert_equal({ 'l0' => 'Partnerverein' }, abgerechnet_bei(p))
  end

  test 'gilt fuer Haupt- und Zusatzlizenz' do
    p = spieler(eintrag(@partner, true), eintrag(@haupt, false), teams: [@sg_rl, @sg_vl])

    assert_equal({ 'l0' => 'Partnerverein', 'l1' => 'Partnerverein' }, abgerechnet_bei(p))
  end

  test 'Heimatverein in der SG ohne weiteren Eintrag: Heimatverein' do
    assert_equal({ 'l0' => 'Partnerverein' }, abgerechnet_bei(spieler(eintrag(@partner, true))))
    assert_equal({ 'l0' => 'Hauptverein' }, abgerechnet_bei(spieler(eintrag(@haupt, true))))
  end

  test 'Heimatverein nicht in der SG: der SG-Verein mit Freigabe' do
    p = spieler(eintrag(@fremd, true), eintrag(@partner, false))

    assert_equal({ 'l0' => 'Partnerverein' }, abgerechnet_bei(p))
  end
end
