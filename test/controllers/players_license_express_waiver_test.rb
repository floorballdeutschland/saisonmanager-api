require 'test_helper'

# Der Expresszuschlag entsteht einmalig beim Antrag (PlayersController#request_license)
# und wurde danach nie wieder geschrieben. Ein wegen fehlender Unterlagen
# abgelehnter Expressantrag blieb deshalb auch dann express, wenn der Verband
# ihn spaeter als gewoehnliche Lizenz erteilte -- abgerechnet wird aber genau
# dieses Flag. Hier steht, was beim Erteilen daran aenderbar ist.
class PlayersLicenseExpressWaiverTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                               'created_at' => 1.day.ago.iso8601 }])
    login_as(create(:user, :admin))
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def license_with(history, express:)
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id,
                                 'league_class_id' => @league.league_class_id,
                                 'express' => express,
                                 'history' => history }])
    id
  end

  def requested(express: true)
    license_with([{ 'license_status_id' => License::REQUESTED, 'created_at' => 3.days.ago.iso8601 }],
                 express: express)
  end

  def approved(express: true)
    license_with([
      { 'license_status_id' => License::REQUESTED, 'created_at' => 3.days.ago.iso8601 },
      { 'license_status_id' => License::APPROVED, 'created_at' => 2.days.ago.iso8601 }
    ], express: express)
  end

  def handle(license_id, status, params = {})
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: status, reason: 'Grund' }.merge(params),
         as: :json
  end

  def license
    @player.reload.licenses.first
  end

  test 'als gewoehnliche Lizenz erteilt streicht den Zuschlag' do
    license_id = requested

    handle(license_id, License::APPROVED, express: false)

    assert_response :success
    assert_equal false, license['express']
    assert_equal License::APPROVED, License.current_status_id(license)
  end

  # Die Abrechnung liest nur das Flag. Wer den Zuschlag wann gestrichen hat,
  # steht danach allein an diesem Eintrag.
  test 'die Streichung ist am Genehmigungseintrag belegt' do
    license_id = requested

    handle(license_id, License::APPROVED, express: false)

    entry = license['history'].last
    assert_equal License::APPROVED, entry['license_status_id'].to_i
    assert_equal true, entry[License::EXPRESS_WAIVED_KEY]
  end

  # Der Wert landet in JSONB und ist damit Bestandsdaten: Eine Umbenennung
  # entwertet jede vorhandene Markierung.
  test 'der Schluessel der Markierung liegt fest' do
    assert_equal 'express_waived', License::EXPRESS_WAIVED_KEY
  end

  test 'als Expresslizenz erteilt laesst den Zuschlag stehen' do
    license_id = requested

    handle(license_id, License::APPROVED, express: true)

    assert_response :success
    assert_equal true, license['express']
    assert_nil license['history'].last[License::EXPRESS_WAIVED_KEY]
  end

  # Ohne den Parameter bleibt es beim bisherigen Verhalten.
  test 'ohne Angabe bleibt der Zuschlag unangetastet' do
    license_id = requested

    handle(license_id, License::APPROVED)

    assert_response :success
    assert_equal true, license['express']
  end

  test 'eine gewoehnliche Lizenz wird nicht nachtraeglich zur Expresslizenz' do
    license_id = requested(express: false)

    handle(license_id, License::APPROVED, express: true)

    assert_response :unprocessable_entity
    assert_equal false, license['express']
    assert_equal License::REQUESTED, License.current_status_id(license),
                 'die Absage darf den Status nicht trotzdem setzen'
  end

  # Die Streichung haengt am Genehmigungseintrag. Bei einer schon erteilten
  # Lizenz entsteht keiner mehr (derselbe Status schreibt keinen zweiten), der
  # Zuschlag fiele also ohne Beleg weg.
  test 'an einer bereits erteilten Lizenz wird die Streichung abgelehnt' do
    license_id = approved

    handle(license_id, License::APPROVED, express: false)

    assert_response :unprocessable_entity
    assert_equal true, license['express']
    assert_equal 2, license['history'].size
  end

  test 'beim Ablehnen laesst sich der Zuschlag nicht aendern' do
    license_id = requested

    handle(license_id, License::DENIED, express: false)

    assert_response :unprocessable_entity
    assert_equal true, license['express']
    assert_equal License::REQUESTED, License.current_status_id(license)
  end

  test 'ein SBK ohne Zustaendigkeit kommt auch mit dem Parameter nicht durch' do
    other_operation = create(:game_operation)
    login_as(create(:user, :sbk_scoped, game_operation_id: other_operation.id))
    license_id = requested

    handle(license_id, License::APPROVED, express: false)

    assert_response :forbidden
    assert_equal true, license['express']
  end
end
