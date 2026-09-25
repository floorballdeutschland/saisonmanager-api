require 'test_helper'

# Reaktivierung einer Lizenz „ungültig wg. Transfer" per Antrag.
#
# Fall: Lizenz fuer Verein A erteilt, Transfer von A nach B (die Lizenz wird
# TRANSFER), danach Freigabe von B zurueck an A. Gleiche Mannschaft und Saison
# nach einem Transfer ist keine neue Lizenz: Der Verein beantragt wie gewohnt,
# request_license haengt den Antrag an den alten Eintrag an, der Verband
# genehmigt ihn wie jeden Antrag. Es bleibt bei einem Eintrag, und die
# Gebuehrenrechnung zaehlt je Eintrag -- die Reaktivierung ist kostenfrei.
class PlayersLicenseReactivationTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club, game_operation: @game_operation)
    @other_club = create(:club, game_operation: @game_operation)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @vm = create(:user, :vm, club_id: @club.id)
    @sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    @player = create(:player, clubs: [
      { 'club_id' => @other_club.id, 'home_club' => true, 'created_at' => 2.days.ago.iso8601 },
      { 'club_id' => @club.id, 'home_club' => false, 'created_at' => 1.day.ago.iso8601,
        'valid_until' => 1.year.from_now.iso8601 }
    ])
    @player.update!(licenses: [transfer_license])
  end

  def transfer_license(id: 'alt', team: @team, extra: {})
    {
      'id' => id, 'team_id' => team.id,
      'season_id' => team.league.season_id, 'league_class_id' => team.league.league_class_id,
      'valid_until' => 1.year.from_now.to_date.iso8601,
      'history' => [
        { 'license_status_id' => License::REQUESTED, 'created_at' => 5.days.ago.iso8601 },
        { 'license_status_id' => License::APPROVED, 'created_at' => 4.days.ago.iso8601 },
        { 'license_status_id' => License::TRANSFER, 'created_at' => 2.days.ago.iso8601, 'reason' => 'Transfer' }
      ]
    }.merge(extra)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def request_license(team: @team, **extra)
    post "/api/v2/user/players/#{@player.id}/request_license", params: { team_id: team.id }.merge(extra), as: :json
  end

  def handle(status, **extra)
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: 'alt', license_status_id: status }.merge(extra), as: :json
  end

  def only_license
    licenses = @player.reload.licenses
    assert_equal 1, licenses.size, 'kein zweiter Lizenzeintrag, also keine zweite Gebuehr'
    licenses.first
  end

  def error_message
    JSON.parse(response.body)['message']
  end

  # --- Der gewollte Weg -----------------------------------------------------

  test 'die Antragsmaske kennzeichnet den Spieler als Reaktivierung' do
    login_as(@vm)
    get "/api/v2/user/team/#{@team.id}/licenses"

    item = JSON.parse(response.body)['other_players'].find { |p| p['id'] == @player.id }
    assert item, 'der zurueckgekehrte Spieler steht in der Auswahl'
    assert_equal true, item['reactivation']
  end

  test 'der Antrag reaktiviert den alten Eintrag, die SBK genehmigt ihn' do
    login_as(@vm)
    request_license

    assert_response :ok
    license = only_license
    current = LicenseEffectiveStatus.current_entry(license)
    assert_equal License::REQUESTED, current['license_status_id'].to_i
    assert current[License::REACTIVATION_KEY]
    assert_nil license['valid_until'], 'das Datum gehoerte zur frueheren Erteilung'

    login_as(@sbk)
    handle(License::APPROVED)

    assert_response :ok
    license = only_license
    assert_equal License::APPROVED, License.current_status_id(license)
    assert license['valid_until'].present?
    assert_equal [License::REQUESTED, License::APPROVED, License::TRANSFER, License::REQUESTED, License::APPROVED],
                 license['history'].map { |h| h['license_status_id'].to_i },
                 'Verlauf: erteilt, Transfer, Reaktivierung beantragt, wieder erteilt'
    assert @player.eligible_for_team?(@team.id, season_id: @league.season_id)
  end

  # Die SBK genehmigt aus der Lizenzverwaltung und sieht dort, dass der
  # Antrag nichts kostet.
  test 'die Lizenzverwaltung kennzeichnet die Reaktivierung' do
    login_as(@vm)
    request_license
    assert_response :ok

    login_as(@sbk)
    get '/api/v2/admin/licenses', params: { season_id: '18' }
    row = JSON.parse(response.body).find { |r| r['player_id'] == @player.id }
    assert row, 'der Antrag steht in der Lizenzverwaltung'
    assert_equal License::REQUESTED, row['license_status_id']
    assert_equal true, row['reactivation']
  end

  test 'die alte Erst-/Zweitlizenz-Zuordnung faellt weg, der Verband legt sie neu fest' do
    @player.update!(licenses: [transfer_license(extra: { 'gf_role' => 'erstlizenz' })])
    login_as(@vm)
    request_license

    assert_response :ok
    license = only_license
    assert_nil license['gf_role']
    assert_equal 'reactivation', license['gf_role_history'].last['source']
  end

  test 'Mitgliedschaft in einem Verein der Spielgemeinschaft genuegt' do
    partner_club = create(:club, game_operation: @game_operation)
    @team.update!(syndicate: true, syndicate_clubs: [partner_club.id])
    @player.update!(clubs: [
      { 'club_id' => @other_club.id, 'home_club' => true, 'created_at' => 2.days.ago.iso8601 },
      { 'club_id' => partner_club.id, 'home_club' => false, 'created_at' => 1.day.ago.iso8601 }
    ])
    login_as(create(:user, :vm, club_id: partner_club.id))

    request_license

    assert_response :ok
    assert_equal 1, @player.reload.licenses.size
  end

  # --- Absagen ---------------------------------------------------------------

  # Player#transfer schliesst die alte Zugehoerigkeit mit `valid_until =
  # Time.now`, und die tagesgenaue Ablaufregel liest sie bis Mitternacht als
  # gueltig. Ohne die Zeitschranke liesse sich am Tag des Wechsels sofort
  # wieder beantragen.
  test 'am Tag des Transfers ohne Freigabe zurueck keine Reaktivierung' do
    @player.update!(clubs: [{ 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 }])
    licenses = [transfer_license]
    licenses.first['history'].last['created_at'] = Time.current.iso8601
    @player.update!(licenses:)
    @player.transfer(@other_club.id, nil)
    @player.save!(validate: false)
    login_as(@vm)

    request_license

    assert_response :unprocessable_entity
    assert_match(/Freigabe erteilt/, error_message)
    assert_equal License::TRANSFER, License.current_status_id(only_license)
  end

  test 'eine Mitgliedschaft von vor dem Transfer zaehlt nicht' do
    clubs = @player.clubs.deep_dup
    clubs.last['created_at'] = 3.days.ago.iso8601
    @player.update!(clubs:)
    login_as(@vm)

    request_license

    assert_response :unprocessable_entity
  end

  test 'eine Reaktivierung ist nie eine Expresslizenz' do
    sa = create(:state_association, sbk_email: 'sbk@example.de', express_license_enabled: true)
    @game_operation.update!(state_association_id: sa.id)
    create(:game_day, league: @league, date: (Date.current + 1).to_s)
    assert @team.reload.express_license_league, 'Aufbau: Express waere sonst moeglich'
    login_as(@vm)

    request_license(express: true)

    assert_response :unprocessable_entity
    assert_match(/kostenfrei/, error_message)
    assert_equal License::TRANSFER, License.current_status_id(only_license)
  end

  # Aus einer Transferlizenz fuehrt fuer den Verband kein direkter Weg: weder
  # erteilen noch der Umweg ueber abgelehnt oder beantragt.
  test 'der Verband setzt eine Transferlizenz nicht direkt um' do
    login_as(@sbk)

    [License::APPROVED, License::DENIED, License::REQUESTED].each do |status|
      handle(status, reason: 'direkt')
      assert_response :unprocessable_entity
      assert_match(/mit einem neuen Antrag/, error_message)
    end
    assert_equal License::TRANSFER, License.current_status_id(only_license)
  end

  # Die Lizenz war vor dem Transfer schon erteilt und abgerechnet.
  test 'bei der Genehmigung der Reaktivierung laesst sich der Expresszuschlag nicht streichen' do
    @player.update!(licenses: [transfer_license(extra: { 'express' => true })])
    login_as(@vm)
    request_license
    assert_response :ok

    login_as(@sbk)
    handle(License::APPROVED, express: false)

    assert_response :unprocessable_entity
    assert_equal true, only_license['express']
  end

  # --- Zurueckziehen ---------------------------------------------------------

  # Innerhalb der Karenzzeit loescht das Zurueckziehen einen Antrag
  # ersatzlos. Hier waere das die frueher erteilte, abgerechnete Lizenz.
  test 'zurueckgezogen wird die Lizenz wieder zur Transferlizenz, nicht geloescht' do
    login_as(@vm)
    request_license
    assert_response :ok

    post "/api/v2/user/players/#{@player.id}/withdraw_license", params: { license_id: 'alt' }, as: :json

    assert_response :ok
    license = only_license
    assert_equal License::TRANSFER, License.current_status_id(license)
    assert_equal 'Reaktivierung zurückgezogen', LicenseEffectiveStatus.current_entry(license)['reason']

    request_license
    assert_response :ok, 'danach laesst sie sich erneut reaktivieren'
  end
end
