require 'test_helper'

# License.change_blocked_reason und die Transferlizenz.
class LicenseChangeBlockedReasonTest < ActiveSupport::TestCase
  def license(*statuses)
    { 'id' => 'x', 'team_id' => 1, 'season_id' => '18',
      'history' => statuses.each_with_index.map do |st, i|
        { 'license_status_id' => st, 'created_at' => (5 - i).days.ago.iso8601 }
      end }
  end

  test 'aus einer Transferlizenz fuehrt kein Statuswechsel des Verbands heraus' do
    transfer = license(License::APPROVED, License::TRANSFER)

    [License::APPROVED, License::DENIED, License::REQUESTED, License::DELETED].each do |target|
      assert License.change_blocked_reason(transfer, target, 'Grund', '18'), "Ziel #{target}"
    end
  end

  test 'die gewoehnliche Erteilung eines Antrags bleibt frei' do
    assert_nil License.change_blocked_reason(license(License::REQUESTED), License::APPROVED, nil, '18')
  end
end

# Auswahl der Gebuehrenrechnung (Player#billable_licenses).
class PlayerBillableLicensesTest < ActiveSupport::TestCase
  setup do
    create(:setting, current_season_id: '18')
    @league = create(:league, :current_season)
    @team = create(:team, league: @league)
    @other_team = create(:team, league: @league)
  end

  def entry(id, team, *statuses)
    { 'id' => id, 'team_id' => team.id, 'season_id' => @league.season_id,
      'history' => statuses.each_with_index.map do |st, i|
        { 'license_status_id' => st, 'created_at' => (10 - i).days.ago.iso8601 }
      end }
  end

  # Altfaelle aus der Zeit vor der Reaktivierung per Antrag: Transferlizenz
  # plus Neuantrag derselben Mannschaft ist fachlich eine Lizenz.
  test 'eine Transferlizenz neben einem weiteren Eintrag derselben Mannschaft zaehlt nicht' do
    player = create(:player, licenses: [
      entry('alt', @team, License::REQUESTED, License::APPROVED, License::TRANSFER),
      entry('neu', @team, License::REQUESTED, License::APPROVED)
    ])

    assert_equal(['neu'], player.billable_licenses(@league.season_id).map { |l| l['id'] })
    assert_equal 0, player.main_license_hash(@league.season_id)[:other_license_count]
  end

  # Wer mitten in der Saison wegwechselt, hatte seine Lizenz beim alten Verein
  # trotzdem: Die bleibt berechnet.
  test 'eine Transferlizenz ohne weiteren Eintrag derselben Mannschaft zaehlt' do
    player = create(:player, licenses: [
      entry('alt', @team, License::REQUESTED, License::APPROVED, License::TRANSFER),
      entry('anders', @other_team, License::REQUESTED, License::APPROVED)
    ])

    assert_equal %w[alt anders], player.billable_licenses(@league.season_id).map { |l| l['id'] }.sort
  end
end
