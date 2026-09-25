require 'test_helper'

# License.change_blocked_reason und die Reaktivierung: Nur ein Wechsel AUS
# einer Transferlizenz erreicht Player#license_reactivation_blocked_reason.
class LicenseChangeBlockedReasonTest < ActiveSupport::TestCase
  def license(*statuses)
    { 'id' => 'x', 'team_id' => 1, 'season_id' => '18',
      'history' => statuses.each_with_index.map do |st, i|
        { 'license_status_id' => st, 'created_at' => (5 - i).days.ago.iso8601 }
      end }
  end

  test 'die gewoehnliche Erteilung eines Antrags fragt die Reaktivierungsregel nicht' do
    player = Player.new(clubs: [], licenses: [])

    assert_nil License.change_blocked_reason(license(License::REQUESTED), License::APPROVED, nil, '18', player:)
  end

  test 'eine Reaktivierung ohne player: ist ein Programmierfehler, keine stille Freigabe' do
    assert_raises(ArgumentError) do
      License.change_blocked_reason(license(License::APPROVED, License::TRANSFER), License::APPROVED, nil, '18')
    end
  end
end
