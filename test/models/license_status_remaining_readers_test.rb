require 'test_helper'

# Die restlichen Leser des aktuellen Lizenzstatus, die den juengsten Eintrag
# als Text oder per `max_by { created_at }` bestimmten (Folge aus #725).
#
# Die Testhistorien bilden eine Offset-Unordnung ab: Der juengere Eintrag
# steht um 18:25 UTC als `18:25:00+00:00`, der aeltere um 17:59 UTC als
# `19:59:00+02:00`. Als Text gewinnt der aeltere.
class LicenseStatusRemainingReadersTest < ActiveSupport::TestCase
  def setup
    @user = create(:user, :admin)
    create(:setting, current_season_id: '18')
    @team = create(:team)
  end

  def entry(status, created_at, extra = {})
    { 'license_status_id' => status, 'created_at' => created_at }.merge(extra)
  end

  def younger(status, extra = {})
    entry(status, '2026-08-03T18:25:00+00:00', extra)
  end

  def older(status, extra = {})
    entry(status, '2026-08-03T19:59:00+02:00', extra)
  end

  def license(history, extra = {})
    { 'id' => SecureRandom.uuid, 'team_id' => @team.id, 'season_id' => '18', 'history' => history }.merge(extra)
  end

  test 'License.current_status_id nimmt den juengeren Eintrag trotz Offset-Unordnung' do
    assert_equal License::APPROVED, License.current_status_id(license([younger(License::APPROVED), older(License::DELETED)]))
  end

  # Ein ungespeicherter Eintrag haelt ein Time-Objekt neben Zeichenketten.
  test 'License.current_status_id ordnet einen ungespeicherten Time-Eintrag richtig ein' do
    l = license([older(License::APPROVED), entry(License::DELETED, Time.utc(2026, 8, 3, 18, 30))])

    assert_equal License::DELETED, License.current_status_id(l)
  end

  test 'License.deletable? erkennt die aktive Lizenz trotz Offset-Unordnung' do
    assert License.deletable?(license([younger(License::APPROVED), older(License::WITHDRAWN)]), '18')
  end

  test 'grace_period_anchor nimmt den juengeren Antrag trotz Offset-Unordnung' do
    anchor = License.grace_period_anchor([younger(License::REQUESTED), older(License::REQUESTED)])

    assert_equal '2026-08-03T18:25:00+00:00', anchor['created_at']
  end

  test 'Player#current_license_status nimmt den juengeren Eintrag trotz Offset-Unordnung' do
    player = create(:player)
    status = player.current_license_status(license([younger(License::APPROVED), older(License::DENIED)]))

    assert_equal License::APPROVED, status['license_status_id']
  end

  # Ohne reload haelt der gerade geschriebene Sperr-Eintrag ein Time-Objekt,
  # die uebrigen sind Zeichenketten.
  test 'lift_suspension! direkt nach suspend! stellt den Status wieder her' do
    player = create(:player, licenses: [license([entry(License::APPROVED, '2026-08-03T10:00:00+02:00')])])
    suspension = player.suspend!(user_id: @user.id, reason: 'Test', games_total: 2)

    player.lift_suspension!(suspension, user_id: @user.id)

    assert_equal License::APPROVED, License.current_status_id(player.reload.licenses.first)
  end

  test 'suspend! setzt keinen zweiten Sperr-Eintrag auf eine schon gesperrte Lizenz' do
    player = create(:player, licenses: [license([younger(License::SUSPENDED), older(License::APPROVED)])])

    player.suspend!(user_id: @user.id, reason: 'Test', games_total: 2)

    assert_equal 2, player.reload.licenses.first['history'].size
  end

  test 'die Lizenzliste der Mannschaft zeigt den juengeren Status trotz Offset-Unordnung' do
    create(:player, clubs: [{ 'club_id' => @team.club_id, 'team_id' => @team.id, 'valid_until' => nil }],
                    licenses: [license([older(License::REQUESTED), younger(License::APPROVED), older(License::DENIED)])])

    item = @team.licenses[:players].first

    assert_not_nil item, 'der Spieler muss in der Lizenzliste stehen'
    assert_equal License::APPROVED, item[:team_license][:last_status_id]
  end
end
