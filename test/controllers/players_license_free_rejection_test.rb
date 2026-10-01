require 'test_helper'

# Kostenfrei ablehnen (License::FREE_REJECTION_KEY): Ein Verein hat in gutem
# Glauben Lizenzen fuer eine Mannschaft beantragt, die es lizenzrechtlich so
# nicht geben kann. Eine gewoehnliche Ablehnung ist kostenpflichtig; diese
# hier nimmt die Lizenz aus der Gebuehrenrechnung und den Expresszuschlag mit.
class PlayersLicenseFreeRejectionTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                               'created_at' => 1.day.ago.iso8601 }])
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def license_with(history, express: false, season_id: @league.season_id)
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => season_id,
                                 'league_class_id' => @league.league_class_id,
                                 'express' => express,
                                 'history' => history }])
    id
  end

  def requested(**)
    license_with([{ 'license_status_id' => License::REQUESTED, 'created_at' => 3.days.ago.iso8601 }], **)
  end

  def handle(license_id, status, params = {})
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: status,
                   reason: 'Pokal-SG nicht zulässig', free_of_charge: true }.merge(params),
         as: :json
  end

  def license
    @player.reload.licenses.first
  end

  def billable_ids
    @player.reload.billable_licenses(@league.season_id).map { |l| l['id'] }
  end

  test 'Admin lehnt kostenfrei ab: abgelehnt, markiert, nicht mehr berechnet' do
    login_as(create(:user, :admin))
    license_id = requested

    handle(license_id, License::DENIED)

    assert_response :success
    entry = license['history'].last
    assert_equal License::DENIED, entry['license_status_id'].to_i
    assert_equal true, entry[License::FREE_REJECTION_KEY]
    assert_equal 'Pokal-SG nicht zulässig', entry['reason']
    assert_empty billable_ids
  end

  # Gegenprobe: Die gewoehnliche Ablehnung bleibt kostenpflichtig.
  test 'gewoehnliche Ablehnung bleibt in der Gebuehrenrechnung' do
    login_as(create(:user, :admin))
    license_id = requested

    handle(license_id, License::DENIED, free_of_charge: false)

    assert_response :success
    assert_nil license['history'].last[License::FREE_REJECTION_KEY]
    assert_equal [license_id], billable_ids
  end

  test 'die SBK darf nicht kostenfrei ablehnen' do
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    license_id = requested

    handle(license_id, License::DENIED)

    assert_response :forbidden
    assert_equal License::REQUESTED, License.current_status_id(license)
  end

  test 'ohne Begruendung keine kostenfreie Ablehnung' do
    login_as(create(:user, :admin))
    license_id = requested

    handle(license_id, License::DENIED, reason: '  ')

    assert_response :unprocessable_entity
    assert_equal License::REQUESTED, License.current_status_id(license)
  end

  # Eine einmal erteilte Lizenz ist abgerechnet. Sonst liesse sie sich per
  # Zuruecksetzen auf `beantragt` und kostenfreier Ablehnung entgebuehren.
  test 'eine schon einmal erteilte Lizenz laesst sich nicht kostenfrei ablehnen' do
    login_as(create(:user, :admin))
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED, 'created_at' => 5.days.ago.iso8601 },
      { 'license_status_id' => License::APPROVED, 'created_at' => 4.days.ago.iso8601 },
      { 'license_status_id' => License::REQUESTED, 'created_at' => 3.days.ago.iso8601 }
    ])

    handle(license_id, License::DENIED)

    assert_response :unprocessable_entity
    assert_match 'bereits erteilt', JSON.parse(response.body)['message']
    assert_equal License::REQUESTED, License.current_status_id(license)
  end

  test 'nur Antraege der laufenden Saison' do
    login_as(create(:user, :admin))
    license_id = requested(season_id: '17')

    handle(license_id, License::DENIED)

    assert_response :unprocessable_entity
    assert_equal License::REQUESTED, License.current_status_id(license)
  end

  test 'kostenfrei gibt es nur zusammen mit der Ablehnung' do
    login_as(create(:user, :admin))
    license_id = requested

    handle(license_id, License::APPROVED)

    assert_response :unprocessable_entity
    assert_equal License::REQUESTED, License.current_status_id(license)
  end

  # Widerruft die SBK die Ablehnung, ist der Antrag wieder offen und wieder
  # kostenpflichtig.
  test 'nach Widerruf der Ablehnung wird wieder berechnet' do
    login_as(create(:user, :admin))
    license_id = requested
    handle(license_id, License::DENIED)
    assert_empty billable_ids

    handle(license_id, License::REQUESTED, free_of_charge: false, reason: 'Ablehnung widerrufen')

    assert_response :success
    assert_equal [license_id], billable_ids
  end

  test 'die Lizenzliste meldet die kostenfreie Ablehnung ohne Expresszuschlag' do
    login_as(create(:user, :admin))
    license_id = requested(express: true)

    handle(license_id, License::DENIED)
    assert_response :success
    assert_equal true, license['express'], 'das Flag selbst bleibt fuer einen Widerruf stehen'

    get '/api/v2/admin/licenses', params: { season_id: @league.season_id }
    assert_response :success
    row = JSON.parse(response.body).find { |r| r['license_id'] == license_id }
    assert row, 'die abgelehnte Lizenz steht in der Liste'
    assert_equal false, row['express']
    assert_equal true, row['free_rejection']
  end

  # Bestandsdaten in JSONB: Eine Umbenennung entwertet jede Markierung.
  test 'der Schluessel der Markierung liegt fest' do
    assert_equal 'free_rejection', License::FREE_REJECTION_KEY
  end
end
