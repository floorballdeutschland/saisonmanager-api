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

  def rejected(express: true)
    license_with([
      { 'license_status_id' => License::REQUESTED, 'created_at' => 30.days.ago.iso8601 },
      { 'license_status_id' => License::DENIED, 'created_at' => 29.days.ago.iso8601 }
    ], express: express)
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
  # Der Anlassfall: Expressantrag, wegen fehlender Unterlagen abgelehnt, Wochen
  # spaeter nachgebessert und ohne Eilbearbeitung erteilt.
  test 'der nachgebesserte Antrag wird ohne Zuschlag erteilt' do
    license_id = rejected

    handle(license_id, License::APPROVED, express: false)

    assert_response :success
    assert_equal false, license['express']
    assert_equal License::APPROVED, License.current_status_id(license)
    assert_equal true, license['history'].last[License::EXPRESS_WAIVED_KEY]
  end

  # Ein leerer Wert sagt nichts aus und darf nicht als "streichen" gelesen
  # werden: Die Absage gegen das Hochstufen macht den Schritt unumkehrbar.
  test 'ein leerer Wert wird abgewiesen' do
    license_id = requested

    handle(license_id, License::APPROVED, express: '')

    assert_response :unprocessable_entity
    assert_equal true, license['express']
    assert_equal License::REQUESTED, License.current_status_id(license)
  end

  # Alles, was nicht als Nein gemeint ist, faellt auf die teure, aber
  # umkehrbare Seite: Der Zuschlag bleibt stehen. Mit dem alten Vergleich
  # `== true || == 'true'` war es genau umgekehrt, und 1 oder "1" haben die
  # Gebuehr gestrichen.
  test 'ein nicht als Nein gemeinter Wert laesst den Zuschlag stehen' do
    [1, '1', 'on', 'vielleicht'].each do |value|
      @player.update!(licenses: [])
      license_id = requested

      handle(license_id, License::APPROVED, express: value)

      assert_response :success, "Wert #{value.inspect}"
      assert_equal true, license['express'], "Wert #{value.inspect}"
      assert_nil license['history'].last[License::EXPRESS_WAIVED_KEY], "Wert #{value.inspect}"
    end
  end

  # Die gaengigen Schreibweisen fuer Nein muessen dagegen greifen, sonst
  # bestellt die Oberflaeche eine Streichung, die stumm nicht stattfindet.
  test 'die Schreibweisen fuer nein streichen den Zuschlag' do
    [false, 'false', 0, '0'].each do |value|
      @player.update!(licenses: [])
      license_id = requested

      handle(license_id, License::APPROVED, express: value)

      assert_response :success, "Wert #{value.inspect}"
      assert_equal false, license['express'], "Wert #{value.inspect}"
    end
  end

  # Bei einer gesperrten Lizenz ist der juengste Eintrag die Sperre. Die
  # darunter liegende Genehmigung ist trotzdem abgerechnet, der Zuschlag darf
  # also auch hier nicht mehr fallen.
  test 'an einer gesperrten, zuvor erteilten Lizenz bleibt der Zuschlag stehen' do
    license_id = license_with([
      { 'license_status_id' => License::REQUESTED, 'created_at' => 30.days.ago.iso8601 },
      { 'license_status_id' => License::APPROVED, 'created_at' => 29.days.ago.iso8601 },
      { 'license_status_id' => License::SUSPENDED, 'created_at' => 2.days.ago.iso8601 }
    ], express: true)

    handle(license_id, License::APPROVED, express: false)

    assert_response :unprocessable_entity
    assert_equal true, license['express']
    assert_equal 3, license['history'].size
  end

  # Gegenstueck zur Absage weiter unten: Der zustaendige SBK muss durchkommen,
  # sonst faellt ein Fehler in die andere Richtung nicht auf.
  test 'der zustaendige SBK darf den Zuschlag streichen' do
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))
    license_id = requested

    handle(license_id, License::APPROVED, express: false)

    assert_response :success
    assert_equal false, license['express']
  end

  # Die Klammer zur Abrechnung: Die Verbands-Lizenzliste ist die Quelle der
  # CSV-Ausfuhr, aus der abgerechnet wird. `false` muss dort als "kein
  # Zuschlag" ankommen, nicht nur ein fehlender Schluessel.
  test 'die Verbandsliste meldet die gestrichene Lizenz als gewoehnliche' do
    license_id = requested

    handle(license_id, License::APPROVED, express: false)
    assert_response :success

    get '/api/v2/admin/licenses', params: { season_id: @league.season_id }

    assert_response :success
    entry = JSON.parse(response.body).find { |e| e['license_id'] == license_id }
    assert_not_nil entry, 'die erteilte Lizenz muss in der Verbandsliste stehen'
    assert_equal false, entry['express']
  end
end
