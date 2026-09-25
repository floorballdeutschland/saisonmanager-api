require 'test_helper'

# Reaktivierung einer Lizenz „ungültig wg. Transfer" nach Freigabe zurueck.
#
# Fall: Lizenz fuer Verein A erteilt, Transfer von A nach B (die Lizenz wird
# TRANSFER), danach Freigabe von B zurueck an A. Seit api#756 kann A neu
# beantragen, das kostet aber ein zweites Mal: Die Gebuehrenrechnung zaehlt je
# Lizenzeintrag der Saison. Die Reaktivierung erteilt stattdessen den alten
# Eintrag wieder (handle_license_request mit `erteilt`), die Regel dahinter
# steht in Player#license_reactivation_blocked_reason.
class PlayersLicenseReactivationTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club, game_operation: @game_operation)
    @other_club = create(:club, game_operation: @game_operation)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    @player = create(:player, clubs: [
      { 'club_id' => @other_club.id, 'home_club' => true, 'created_at' => 2.days.ago.iso8601 },
      { 'club_id' => @club.id, 'home_club' => false, 'created_at' => 1.day.ago.iso8601,
        'valid_until' => 1.year.from_now.iso8601 }
    ])
    @player.update!(licenses: [transfer_license])
  end

  def transfer_license(id: 'alt', team: @team, season_id: @league.season_id, extra: {})
    {
      'id' => id, 'team_id' => team.id,
      'season_id' => season_id, 'league_class_id' => @league.league_class_id,
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

  def reactivate(license_id = 'alt', **extra)
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::APPROVED,
                   reason: 'Reaktiviert nach Freigabe' }.merge(extra),
         as: :json
  end

  def profile_license(id = 'alt')
    get "/api/v2/admin/players/#{@player.id}.json"
    assert_response :success
    JSON.parse(response.body)['licenses'].find { |l| l['id'] == id }
  end

  def error_message
    JSON.parse(response.body)['message']
  end

  # --- Der gewollte Weg -----------------------------------------------------

  test 'SBK reaktiviert die Transferlizenz: ein Eintrag, wieder erteilt' do
    login_as(@sbk)
    assert profile_license['reactivate_allowed'], 'der Knopf muss erscheinen'

    reactivate

    assert_response :ok
    @player.reload
    assert_equal 1, @player.licenses.size, 'kein zweiter Lizenzeintrag, also keine zweite Gebuehr'
    license = @player.licenses.first
    assert_equal License::APPROVED, License.current_status_id(license)
    assert license['valid_until'].present?
    assert_equal [License::REQUESTED, License::APPROVED, License::TRANSFER, License::APPROVED],
                 license['history'].map { |h| h['license_status_id'].to_i },
                 'Verlauf: erteilt, Transfer, wieder erteilt'
    assert @player.eligible_for_team?(@team.id, season_id: @league.season_id)
    assert_equal false, profile_license['reactivate_allowed']
  end

  # --- Absagen ---------------------------------------------------------------

  test 'ohne Mitgliedschaft im Lizenzverein keine Reaktivierung' do
    @player.update!(clubs: [{ 'club_id' => @other_club.id, 'home_club' => true,
                              'created_at' => 2.days.ago.iso8601 }])
    login_as(@sbk)
    assert_equal false, profile_license['reactivate_allowed']

    reactivate

    assert_response :unprocessable_entity
    assert_match(/nicht wieder Mitglied/, error_message)
    assert_equal License::TRANSFER, License.current_status_id(@player.reload.licenses.first)
  end

  test 'abgelaufene Mitgliedschaft zaehlt nicht' do
    clubs = @player.clubs.deep_dup
    clubs.last['valid_until'] = 1.day.ago.iso8601
    @player.update!(clubs:)
    login_as(@sbk)

    reactivate

    assert_response :unprocessable_entity
  end

  # Der Fall vom 24.09.: Der Verein hat schon neu beantragt. Zwei aktive
  # Lizenzen fuer dieselbe Mannschaft darf die Reaktivierung nicht erzeugen.
  test 'neben einem Neuantrag derselben Mannschaft keine Reaktivierung' do
    neu = { 'id' => 'neu', 'team_id' => @team.id, 'season_id' => @league.season_id,
            'history' => [{ 'license_status_id' => License::REQUESTED, 'created_at' => 1.hour.ago.iso8601 }] }
    @player.update!(licenses: [transfer_license, neu])
    login_as(@sbk)
    assert_equal false, profile_license['reactivate_allowed']

    reactivate

    assert_response :unprocessable_entity
    assert_match(/schon eine beantragte oder erteilte Lizenz/, error_message)
  end

  test 'ein zurueckgezogener Neuantrag steht der Reaktivierung nicht im Weg' do
    neu = { 'id' => 'neu', 'team_id' => @team.id, 'season_id' => @league.season_id,
            'history' => [{ 'license_status_id' => License::REQUESTED, 'created_at' => 3.hours.ago.iso8601 },
                          { 'license_status_id' => License::WITHDRAWN, 'created_at' => 1.hour.ago.iso8601 }] }
    @player.update!(licenses: [transfer_license, neu])
    login_as(@sbk)

    reactivate

    assert_response :ok
  end

  test 'Lizenz einer vergangenen Saison laesst sich nicht reaktivieren' do
    @player.update!(licenses: [transfer_license(season_id: '17')])
    login_as(@sbk)
    assert_equal false, profile_license['reactivate_allowed']

    reactivate

    assert_response :unprocessable_entity
    assert_match(/laufenden Saison/, error_message)
  end

  test 'eine Sperre fuer die Mannschaft verhindert die Reaktivierung' do
    PlayerSuspension.create!(player: @player, team_id: @team.id,
                             valid_from: 1.day.ago.to_date, valid_until: 1.month.from_now.to_date)
    login_as(@sbk)

    reactivate

    assert_response :unprocessable_entity
    assert_equal License::TRANSFER, License.current_status_id(@player.reload.licenses.first)
  end

  test 'SBK eines fremden Spielbetriebs darf nicht reaktivieren' do
    login_as(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

    reactivate

    assert_response :forbidden
  end

  # Player#transfer schliesst die alte Zugehoerigkeit mit `valid_until =
  # Time.now`, und die tagesgenaue Ablaufregel liest sie bis Mitternacht als
  # gueltig. Ohne die Zeitschranke liesse sich die Lizenz am Tag des Wechsels
  # sofort wieder erteilen.
  test 'am Tag des Transfers ohne Freigabe zurueck keine Reaktivierung' do
    @player.update!(clubs: [
      { 'club_id' => @club.id, 'home_club' => true, 'created_at' => 1.year.ago.iso8601 }
    ])
    licenses = [transfer_license]
    licenses.first['history'].last['created_at'] = Time.current.iso8601
    @player.update!(licenses:)
    @player.transfer(@other_club.id, nil)
    @player.save!(validate: false)
    login_as(@sbk)
    lic = profile_license
    assert_equal false, lic['reactivate_allowed']
    assert_match(/nicht wieder Mitglied/, lic['reactivate_blocked_reason'])

    reactivate

    assert_response :unprocessable_entity
    assert_equal License::TRANSFER, License.current_status_id(@player.reload.licenses.first)
  end

  test 'eine Mitgliedschaft von vor dem Transfer zaehlt nicht' do
    clubs = @player.clubs.deep_dup
    clubs.last['created_at'] = 3.days.ago.iso8601
    @player.update!(clubs:)
    login_as(@sbk)

    reactivate

    assert_response :unprocessable_entity
  end

  test 'Mitgliedschaft in einem Verein der Spielgemeinschaft genuegt' do
    partner_club = create(:club, game_operation: @game_operation)
    @team.update!(syndicate: true, syndicate_clubs: [partner_club.id])
    @player.update!(clubs: [
      { 'club_id' => @other_club.id, 'home_club' => true, 'created_at' => 2.days.ago.iso8601 },
      { 'club_id' => partner_club.id, 'home_club' => false, 'created_at' => 1.day.ago.iso8601 }
    ])
    login_as(@sbk)
    assert profile_license['reactivate_allowed']

    reactivate

    assert_response :ok
  end

  test 'eine erteilte zweite Lizenz derselben Mannschaft sperrt, eine der Vorsaison nicht' do
    vorjahr = { 'id' => 'vorjahr', 'team_id' => @team.id, 'season_id' => '17',
                'history' => [{ 'license_status_id' => License::APPROVED, 'created_at' => 1.year.ago.iso8601 }] }
    @player.update!(licenses: [transfer_license, vorjahr])
    login_as(@sbk)
    assert profile_license['reactivate_allowed'], 'die Vorsaison zaehlt nicht als Doppellizenz'

    erteilt = vorjahr.merge('id' => 'erteilt', 'season_id' => @league.season_id)
    @player.update!(licenses: [transfer_license, erteilt])
    assert_equal false, profile_license['reactivate_allowed']
  end

  # Der Umweg: erst ablehnen oder beantragen, dann erteilen. Das `erteilt`
  # traefe keine Transferlizenz mehr und liefe an allen Pruefungen vorbei.
  test 'aus einer Transferlizenz fuehrt kein Weg ausser der Reaktivierung' do
    @player.update!(clubs: [{ 'club_id' => @other_club.id, 'home_club' => true,
                              'created_at' => 2.days.ago.iso8601 }])
    login_as(@sbk)

    [License::DENIED, License::REQUESTED].each do |status|
      post "/api/v2/admin/players/#{@player.id}/handle_license_request",
           params: { license_id: 'alt', license_status_id: status, reason: 'Umweg' }, as: :json
      assert_response :unprocessable_entity
      assert_match(/nur reaktivieren/, error_message)
    end
    assert_equal License::TRANSFER, License.current_status_id(@player.reload.licenses.first)
  end

  # Die Lizenz war vor dem Transfer schon erteilt und abgerechnet.
  test 'bei der Reaktivierung laesst sich der Expresszuschlag nicht streichen' do
    @player.update!(licenses: [transfer_license(extra: { 'express' => true })])
    login_as(@sbk)

    reactivate('alt', express: false)

    assert_response :unprocessable_entity
    assert_equal true, @player.reload.licenses.first['express']
  end

  test 'Admin reaktiviert ebenso' do
    login_as(create(:user, :admin))
    assert profile_license['reactivate_allowed']

    reactivate

    assert_response :ok
  end

  # Der Knopf haengt am Spielbetrieb der Liga, nicht nur am flachen Recht.
  test 'reactivate_allowed folgt dem Verbands-Scope je Lizenz' do
    fremde_liga = create(:league, :current_season, game_operation: create(:game_operation))
    fremdes_team = create(:team, league: fremde_liga, club: @club)
    @player.update!(licenses: [transfer_license, transfer_license(id: 'fremd', team: fremdes_team)])
    login_as(@sbk)
    get "/api/v2/admin/players/#{@player.id}.json"
    lizenzen = JSON.parse(response.body)['licenses'].index_by { |l| l['id'] }

    assert lizenzen['alt']['reactivate_allowed']
    assert_equal false, lizenzen['fremd']['reactivate_allowed']
    assert_nil lizenzen['fremd']['reactivate_blocked_reason']
  end

  # --- Erst-/Zweitlizenz ------------------------------------------------------

  test 'mit Partnerlizenz im GF-Wettbewerb muss die Zuordnung festgelegt werden' do
    setup_gf_partner
    login_as(@sbk)

    reactivate

    assert_response :unprocessable_entity
    assert_match(/Erst- oder Zweitlizenz/, error_message)

    reactivate('alt', gf_role: 'zweitlizenz')

    assert_response :ok
    roles = @player.reload.licenses.to_h { |l| [l['id'], l['gf_role']] }
    assert_equal({ 'alt' => 'zweitlizenz', 'partner' => 'erstlizenz' }, roles)
  end

  test 'als Erstlizenz reaktiviert, wird die Partnerlizenz zur Zweitlizenz' do
    setup_gf_partner
    login_as(@sbk)

    reactivate('alt', gf_role: 'erstlizenz')

    assert_response :ok
    partner = @player.reload.licenses.find { |l| l['id'] == 'partner' }
    assert_equal 'zweitlizenz', partner['gf_role']
    assert_equal 'auto', partner['gf_role_history'].last['source']
  end

  def setup_gf_partner
    gf_league = create(:league, :current_season, game_operation: @game_operation,
                                                 field_size: 'GF', age_group: 'Herren')
    gf_team = create(:team, league: gf_league, club: @club)
    other_team = create(:team, league: create(:league, :current_season, game_operation: @game_operation,
                                                                        field_size: 'GF', age_group: 'Herren'),
                               club: @other_club)
    partner = { 'id' => 'partner', 'team_id' => other_team.id, 'season_id' => gf_league.season_id,
                'gf_role' => 'erstlizenz',
                'history' => [{ 'license_status_id' => License::APPROVED, 'created_at' => 1.day.ago.iso8601 }] }
    @player.update!(licenses: [transfer_license(team: gf_team, season_id: gf_league.season_id,
                                                extra: { 'gf_role' => 'erstlizenz' }), partner])
  end
end
