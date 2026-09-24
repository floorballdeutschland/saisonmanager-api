require 'test_helper'

class PlayerLicensesByTeamTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @team = create(:team)
  end

  def license(*entries)
    {
      'id' => Digest::UUID.uuid_v4, 'team_id' => @team.id,
      'history' => entries.map { |status, at| { 'license_status_id' => status, 'created_at' => at.iso8601 } }
    }
  end

  test 'die aktive Lizenz gewinnt gegen eine aeltere Transferlizenz' do
    old = license([License::APPROVED, 4.days.ago], [License::TRANSFER, 2.days.ago])
    fresh = license([License::APPROVED, 1.day.ago])
    player = build(:player, licenses: [old, fresh])

    assert_equal fresh['id'], player.licenses_by_team(@team.id)['id']
  end

  test 'ohne aktive Lizenz gilt die zuletzt geaenderte' do
    old = license([License::APPROVED, 4.days.ago], [License::TRANSFER, 2.days.ago])
    denied = license([License::REQUESTED, 1.day.ago], [License::DENIED, 1.hour.ago])
    player = build(:player, licenses: [old, denied])

    assert_equal denied['id'], player.licenses_by_team(@team.id)['id']
  end

  test 'Lizenz ohne Verlauf wirft nicht und verliert gegen eine mit Verlauf' do
    empty = { 'id' => 'leer', 'team_id' => @team.id }
    old = license([License::TRANSFER, 2.days.ago])
    player = build(:player, licenses: [empty, old])

    assert_equal old['id'], player.licenses_by_team(@team.id)['id']
  end

  test 'Lizenz einer anderen Mannschaft zaehlt nicht' do
    other = license([License::APPROVED, 1.day.ago]).merge('team_id' => create(:team).id)
    player = build(:player, licenses: [other])

    assert_nil player.licenses_by_team(@team.id)
  end
end
