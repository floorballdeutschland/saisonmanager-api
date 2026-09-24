require 'test_helper'

# Player#license_for_team (und licenses_by_team darueber): welche Lizenz einer
# Mannschaft gilt, wenn der Spieler mehrere fuer sie traegt.
class PlayerLicensesByTeamTest < ActiveSupport::TestCase
  setup do
    create(:setting)
    @team = create(:team)
  end

  def license(*entries, season_id: nil)
    {
      'id' => SecureRandom.hex(4), 'team_id' => @team.id, 'season_id' => season_id,
      'history' => entries.map { |status, at| { 'license_status_id' => status, 'created_at' => at.iso8601 } }
    }.compact
  end

  test 'die aktive Lizenz gewinnt gegen eine aeltere Transferlizenz' do
    old = license([License::APPROVED, 4.days.ago], [License::TRANSFER, 2.days.ago])
    fresh = license([License::APPROVED, 1.day.ago])
    player = build(:player, licenses: [old, fresh])

    assert_equal fresh['id'], player.licenses_by_team(@team.id)['id']
  end

  test 'ein offener Antrag gewinnt gegen eine juengere Ablehnung' do
    requested = license([License::REQUESTED, 3.days.ago])
    denied = license([License::REQUESTED, 2.days.ago], [License::DENIED, 1.day.ago])
    player = build(:player, licenses: [denied, requested])

    assert_equal requested['id'], player.license_for_team(@team.id)['id']
  end

  # Gemessen am Basisstatus, nicht am juengsten Eintrag: Die gesperrte Lizenz
  # ist erteilt und gilt, auch wenn der Transfereintrag der alten juenger ist.
  test 'eine gesperrte erteilte Lizenz gilt vor der Transferlizenz' do
    old = license([License::APPROVED, 4.days.ago], [License::TRANSFER, 1.hour.ago])
    suspended = license([License::APPROVED, 2.days.ago], [License::SUSPENDED, 1.day.ago])
    player = build(:player, licenses: [old, suspended])

    assert_equal suspended['id'], player.license_for_team(@team.id)['id']
  end

  test 'ohne aktive Lizenz gilt die zuletzt geaenderte' do
    old = license([License::APPROVED, 4.days.ago], [License::TRANSFER, 2.days.ago])
    denied = license([License::REQUESTED, 1.day.ago], [License::DENIED, 1.hour.ago])
    player = build(:player, licenses: [old, denied])

    assert_equal denied['id'], player.licenses_by_team(@team.id)['id']
  end

  test 'eine Lizenz ohne Verlauf verliert gegen eine mit Verlauf' do
    empty = { 'id' => 'leer', 'team_id' => @team.id }
    old = license([License::TRANSFER, 2.days.ago])
    player = build(:player, licenses: [empty, old])

    assert_equal old['id'], player.licenses_by_team(@team.id)['id']
  end

  test 'mit Saison zaehlt nur eine Lizenz dieser Saison' do
    current = license([License::TRANSFER, 2.days.ago], season_id: '18')
    other = license([License::APPROVED, 1.day.ago], season_id: '17')
    player = build(:player, licenses: [other, current])

    assert_equal current['id'], player.license_for_team(@team.id, season_id: '18')['id']
  end

  test 'Lizenz einer anderen Mannschaft und kaputte Eintraege zaehlen nicht' do
    other = license([License::APPROVED, 1.day.ago]).merge('team_id' => create(:team).id)
    player = build(:player, licenses: [other, 'kaputt'])

    assert_nil player.licenses_by_team(@team.id)
    assert_nil build(:player, licenses: nil).licenses_by_team(@team.id)
  end
end
