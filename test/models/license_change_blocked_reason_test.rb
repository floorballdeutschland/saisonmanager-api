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

  # Eine schon gewoehnlich abgelehnte Lizenz wird nicht nachtraeglich kostenfrei.
  test 'eine abgelehnte Lizenz laesst sich nicht kostenfrei ablehnen' do
    assert_equal 'Nur beantragte Lizenzen lassen sich kostenfrei ablehnen.',
                 License.change_blocked_reason(license(License::REQUESTED, License::DENIED),
                                               License::DENIED, 'Grund', '18', free_of_charge: true)
  end
end

# License.free_rejection? liest den juengsten Eintrag nach Zeitpunkt, nicht
# nach Position im Array.
class LicenseFreeRejectionTest < ActiveSupport::TestCase
  def license(*entries)
    { 'id' => 'x', 'team_id' => 1, 'season_id' => '18', 'history' => entries }
  end

  def requested(days_ago)
    { 'license_status_id' => License::REQUESTED, 'created_at' => days_ago.days.ago.iso8601 }
  end

  def free_denied(days_ago, marker: true)
    { 'license_status_id' => License::DENIED, 'created_at' => days_ago.days.ago.iso8601,
      License::FREE_REJECTION_KEY => marker }
  end

  test 'die markierte Ablehnung zaehlt auch, wenn sie nicht hinten im Array steht' do
    assert License.free_rejection?(license(free_denied(1), requested(3)))
  end

  test 'ein juengerer Antrag weiter vorn im Array hebt die Markierung auf' do
    assert_not License.free_rejection?(license(requested(1), requested(5), free_denied(3)))
  end

  # JSONB ist nicht typgarantiert: Nur das echte true gilt, ein Text nicht.
  test 'ein Text statt true markiert nicht' do
    assert_not License.free_rejection?(license(requested(3), free_denied(1, marker: 'true')))
  end

  test 'eine gewoehnliche Ablehnung ist keine kostenfreie' do
    assert_not License.free_rejection?(license(requested(3), requested(2).merge('license_status_id' => License::DENIED)))
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

  # Ein abgelehnter oder zurueckgezogener Neuantrag war nie eine Spielberechtigung:
  # Stehen bleibt die Transferlizenz, die erteilt war.
  test 'neben einem abgelehnten Neuantrag bleibt die Transferlizenz stehen' do
    player = create(:player, licenses: [
      entry('alt', @team, License::REQUESTED, License::APPROVED, License::TRANSFER),
      entry('neu', @team, License::REQUESTED, License::DENIED)
    ])

    assert_equal(['alt'], player.billable_licenses(@league.season_id).map { |l| l['id'] })
  end

  test 'zwei Transferlizenzen derselben Mannschaft zaehlen einmal' do
    player = create(:player, licenses: [
      entry('alt', @team, License::REQUESTED, License::APPROVED, License::TRANSFER),
      entry('neu', @team, License::REQUESTED, License::APPROVED, License::TRANSFER)
    ])

    assert_equal 1, player.billable_licenses(@league.season_id).size
  end

  def free_denied(id, team)
    entry(id, team, License::REQUESTED, License::DENIED).tap do |lic|
      lic['history'].last[License::FREE_REJECTION_KEY] = true
    end
  end

  # Beide Dateien der Gebuehrenrechnung: Die kostenfrei abgelehnte Lizenz ist
  # weder Haupt- noch weitere Lizenz.
  test 'eine kostenfrei abgelehnte Lizenz faellt aus beiden Dateien der Gebuehrenrechnung' do
    player = create(:player, licenses: [
      free_denied('pokal', @other_team),
      entry('liga', @team, License::REQUESTED, License::APPROVED)
    ])

    main = player.main_license_hash(@league.season_id)
    assert_equal 'liga', JSON.parse(main[:license])['id']
    assert_equal 0, main[:other_license_count]
    assert_equal [], player.secondary_license_hash(@league.season_id)
  end

  test 'eine gewoehnlich abgelehnte Lizenz bleibt in der Gebuehrenrechnung' do
    player = create(:player, licenses: [
      entry('pokal', @other_team, License::REQUESTED, License::DENIED),
      entry('liga', @team, License::REQUESTED, License::APPROVED)
    ])

    assert_equal 1, player.main_license_hash(@league.season_id)[:other_license_count]
  end

  test 'nur eine kostenfrei abgelehnte Lizenz: nichts zu berechnen' do
    player = create(:player, licenses: [free_denied('pokal', @team)])

    assert_equal [], player.billable_licenses(@league.season_id)
    assert_equal [], player.secondary_license_hash(@league.season_id)
  end

  # Die zweite Datei der Gebuehrenrechnung (weitere Lizenzen) laeuft ueber
  # dieselbe Auswahl.
  test 'die weiteren Lizenzen der Gebuehrenrechnung enthalten die Transferlizenz nicht' do
    player = create(:player, licenses: [
      entry('alt', @team, License::REQUESTED, License::APPROVED, License::TRANSFER),
      entry('neu', @team, License::REQUESTED, License::APPROVED)
    ])

    assert_equal [], player.secondary_license_hash(@league.season_id)
  end
end
