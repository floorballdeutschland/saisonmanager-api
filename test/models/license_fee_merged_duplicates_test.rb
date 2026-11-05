require 'test_helper'

# Lizenzen zusammengefuehrter Dubletten in der Gebuehrenrechnung.
#
# Regel: Wird eine Dublette zusammengefuehrt, zaehlen alle ihre Lizenzen, als
# gehoerten sie dem Master. Bis hierher lief die Rechnung ueber `Player.all` und
# berechnete die Lizenzen, die `merge_into!` auf den Master kopiert, bei der
# Dublette ein zweites Mal voll. Stichtag 31.10.2026: fuenf Dubletten, 70 EUR,
# darunter ein abgelehnter Antrag vor der Zusammenfuehrung, beim Master dieselbe
# Lizenz neu beantragt und erteilt.
class LicenseFeeCalculationMergedTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @user = create(:user)
    @league_rl = create(:league, :current_season, league_class_id: 'rl')
    @league_vl = create(:league, :current_season, league_class_id: 'vl')
    @team_rl = create(:team, league: @league_rl)
    @team_vl = create(:team, league: @league_vl)
  end

  def lizenz(id, team, *statuses)
    { 'id' => id, 'team_id' => team.id, 'season_id' => '18',
      'league_class_id' => team.league.league_class_id,
      'history' => statuses.each_with_index.map do |st, i|
        { 'license_status_id' => st, 'created_at' => (10 - i).days.ago.iso8601 }
      end }
  end

  def rechnung
    LicenseFeeCalculation.start_calculation(@user.id, '18')
  end

  def zeilen(calc, player)
    main = calc.interal_hash.compact.select { |r| r[:id] == player.id && r[:license_id].present? }
    other = calc.other_hash.select { |r| r[:id] == player.id }
    [main, other]
  end

  test 'die Dublette erscheint nicht mehr, ihre Lizenz steht beim Master als Zusatzlizenz' do
    master = create(:player, licenses: [lizenz('m-rl', @team_rl, License::REQUESTED, License::APPROVED)])
    dublette = create(:player, licenses: [lizenz('d-vl', @team_vl, License::REQUESTED, License::APPROVED)])
    dublette.merge_into!(master, @user.id)

    calc = rechnung

    assert_empty(calc.interal_hash.compact.select { |r| r[:id] == dublette.id })
    assert_empty(calc.other_hash.select { |r| r[:id] == dublette.id })

    main, other = zeilen(calc, master)
    assert_equal(['m-rl'], main.map { |r| r[:license_id] })
    assert_equal(['d-vl'], other.map { |r| r[:license_id] })
    assert_empty calc.merge_warnings
  end

  # Dieselbe Lizenz, bei der Dublette abgelehnt, beim Master
  # nach der Zusammenfuehrung neu beantragt und erteilt.
  test 'eine abgelehnte Lizenz der Dublette, die beim Master weiterlief, zaehlt einmal' do
    master = create(:player)
    dublette = create(:player, licenses: [lizenz('x', @team_vl, License::REQUESTED, License::DENIED)])
    dublette.merge_into!(master, @user.id)
    master.reload
    master.licenses.first['history'] << { 'license_status_id' => License::APPROVED,
                                          'created_at' => Time.current.iso8601 }
    master.save!(validate: false)

    calc = rechnung

    main, other = zeilen(calc, master)
    assert_equal(['x'], main.map { |r| r[:license_id] })
    assert_empty other
    assert_empty(calc.interal_hash.compact.select { |r| r[:id] == dublette.id && r[:license_id].present? })
  end

  # Gleiche Mannschaft, verschiedene Lizenz-IDs. `merge_into!`
  # mischt den Verlauf in die Lizenz des Masters, es bleibt eine Lizenz.
  test 'eine Lizenz derselben Mannschaft mit anderer ID zaehlt nicht zusaetzlich' do
    master = create(:player, licenses: [lizenz('m', @team_vl, License::REQUESTED, License::APPROVED)])
    dublette = create(:player, licenses: [lizenz('d', @team_vl, License::REQUESTED, License::APPROVED)])
    dublette.merge_into!(master, @user.id)

    calc = rechnung

    main, other = zeilen(calc, master)
    assert_equal(['m'], main.map { |r| r[:license_id] })
    assert_empty other
    assert_empty calc.merge_warnings
  end

  # Altbestand: zusammengefuehrt, ohne dass die Lizenz auf den Master kam.
  test 'eine beim Master fehlende Lizenz wird ihm als Zusatzlizenz zugerechnet und gemeldet' do
    master = create(:player, licenses: [lizenz('m-rl', @team_rl, License::REQUESTED, License::APPROVED)])
    dublette = create(:player, licenses: [lizenz('d-vl', @team_vl, License::REQUESTED, License::DELETED)])
    dublette.update_column(:merged_into_id, master.id)

    calc = rechnung

    main, other = zeilen(calc, master)
    assert_equal(['m-rl'], main.map { |r| r[:license_id] })
    assert_equal(['d-vl'], other.map { |r| r[:license_id] })
    assert_equal dublette.id, other.first[:merged_from_id]
    assert_equal 1, main.first[:other_license_count]
    assert_equal 1, calc.merge_warnings.size
    assert_match "##{dublette.id}", calc.merge_warnings.first
    assert_empty(calc.interal_hash.compact.select { |r| r[:id] == dublette.id })
  end

  test 'eine beim Master fehlende hoehere Lizenz wird seine Hauptlizenz' do
    master = create(:player, licenses: [lizenz('m-vl', @team_vl, License::REQUESTED, License::APPROVED)])
    dublette = create(:player, licenses: [lizenz('d-rl', @team_rl, License::REQUESTED, License::APPROVED)])
    dublette.update_column(:merged_into_id, master.id)

    calc = rechnung

    main, other = zeilen(calc, master)
    assert_equal(['d-rl'], main.map { |r| r[:license_id] })
    assert_equal dublette.id, main.first[:merged_from_id]
    assert_equal(['m-vl'], other.map { |r| r[:license_id] })
    assert_nil other.first[:merged_from_id]
  end

  test 'bei einer Kette zaehlt die Lizenz beim letzten Master' do
    master = create(:player)
    zwischen = create(:player)
    dublette = create(:player, licenses: [lizenz('d', @team_vl, License::REQUESTED, License::APPROVED)])
    zwischen.update_column(:merged_into_id, master.id)
    dublette.update_column(:merged_into_id, zwischen.id)

    calc = rechnung

    main, = zeilen(calc, master)
    assert_equal(['d'], main.map { |r| r[:license_id] })
    assert_empty(calc.interal_hash.compact.select { |r| [zwischen.id, dublette.id].include?(r[:id]) })
  end

  test 'die Rechnung schreibt nichts an den Master' do
    master = create(:player, licenses: [lizenz('m', @team_rl, License::REQUESTED, License::APPROVED)])
    dublette = create(:player, licenses: [lizenz('d', @team_vl, License::REQUESTED, License::APPROVED)])
    dublette.update_column(:merged_into_id, master.id)

    rechnung

    assert_equal(['m'], master.reload.licenses.map { |l| l['id'] })
  end
end
