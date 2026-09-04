require 'test_helper'

# Das Löschen einer Lizenz durch den Verband (Status License::DELETED über
# handle_license_request). Es ist der einzige Statuswechsel mit Pflicht-Freitext,
# und die Regel dahinter steht in License.deletable? / .delete_blocked_reason.
#
# Eigene Datei, weil players_controller_test.rb nahe an Metrics/ClassLength
# (Max 1000, .rubocop_todo.yml) liegt.
class PlayersLicenseDeleteTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club, game_operation: @game_operation)
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

  # Eine Lizenz mit dem Verlauf "beantragt -> erteilt", also der Normalfall, den
  # der Verband löschen können soll.
  def approved_license(season_id: @league.season_id, extra: {})
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => season_id,
                                 'league_class_id' => @league.league_class_id,
                                 'history' => [
                                   { 'license_status_id' => License::REQUESTED,
                                     'created_at' => 3.days.ago.iso8601, 'created_by' => nil },
                                   { 'license_status_id' => License::APPROVED,
                                     'created_at' => 2.days.ago.iso8601, 'created_by' => nil }
                                 ] }.merge(extra)])
    id
  end

  def delete_license(license_id, reason: 'Doppelt angelegt, siehe Mail des Vereins')
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::DELETED, reason: reason },
         as: :json
  end

  def current_entry
    @player.reload.licenses.first['history'].max_by { |h| h['created_at'] }
  end

  # --- Doppelte Lizenz-ids im selben Profil ---------------------------------
  #
  # Nach einer Zusammenfuehrung kann dieselbe id zweimal im Profil stehen:
  # _merge_licenses fasst nur bei gleichem team_id UND season_id zusammen.
  # Geprueft wurde bisher der erste Treffer, geschrieben hat das map! JEDEN --
  # eine Loeschung traf damit auch die abgerechnete Lizenz einer alten Saison,
  # die License.deletable? gerade ausschliesst.

  test 'loescht nur den geprueften Eintrag, nicht jeden mit derselben id' do
    doppel_id = Digest::UUID.uuid_v4
    verlauf = lambda do |zeitpunkt|
      [{ 'license_status_id' => License::APPROVED,
         'created_at' => zeitpunkt, 'created_by' => nil }]
    end
    @player.update!(licenses: [
                      { 'id' => doppel_id, 'team_id' => @team.id,
                        'season_id' => @league.season_id,
                        'history' => verlauf.call(2.days.ago.iso8601) },
                      { 'id' => doppel_id, 'team_id' => @team.id,
                        'season_id' => '15',
                        'history' => verlauf.call(3.years.ago.iso8601) }
                    ])
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(doppel_id, reason: 'Doppelt angelegt, siehe Mail des Vereins')

    assert_response :ok
    lizenzen = @player.reload.licenses
    assert_equal License::DELETED,
                 lizenzen[0]['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i,
                 'die gepruefte Lizenz der laufenden Saison muss geloescht sein'
    assert_equal License::APPROVED,
                 lizenzen[1]['history'].max_by { |h| h['created_at'] }['license_status_id'].to_i,
                 'die abgerechnete Altsaison darf NICHT mitgeloescht werden'
  end

  # --- Verbands-Scope am Knopf ----------------------------------------------

  # Die eigene Lizenz ja, die des fremden Verbandes nein -- und beides im selben
  # Profil, denn genau so tritt der Fall auf: Eine Landes-SBK sieht das Profil
  # ihres Heimatspielers, der zusaetzlich eine Lizenz in einem Bundesliga-Team
  # eines anderen Spielbetriebs haelt. `delete_allowed` kannte den Spielbetrieb
  # nicht, der rote Knopf stand also auch dort, und der Klick endete nach
  # eingegebener Begruendung in einer 403.
  test 'delete_allowed folgt dem Verbands-Scope je Lizenz' do
    fremder_verband = create(:game_operation)
    fremde_liga = create(:league, :current_season, game_operation: fremder_verband)
    fremdes_team = create(:team, league: fremde_liga, club: create(:club, game_operation: fremder_verband))

    eigene_id = Digest::UUID.uuid_v4
    fremde_id = Digest::UUID.uuid_v4
    verlauf = [{ 'license_status_id' => License::APPROVED,
                 'created_at' => 2.days.ago.iso8601, 'created_by' => nil }]
    @player.update!(licenses: [
                      { 'id' => eigene_id, 'team_id' => @team.id,
                        'season_id' => @league.season_id, 'history' => verlauf },
                      { 'id' => fremde_id, 'team_id' => fremdes_team.id,
                        'season_id' => fremde_liga.season_id, 'history' => verlauf }
                    ])
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    get "/api/v2/admin/players/#{@player.id}.json"

    assert_response :success
    nach_id = JSON.parse(response.body)['licenses'].index_by { |l| l['id'] }
    assert_equal true, nach_id[eigene_id]['delete_allowed'],
                 'die eigene Lizenz muss loeschbar bleiben'
    assert_equal false, nach_id[fremde_id]['delete_allowed'],
                 'der rote Knopf darf bei einem fremden Verband gar nicht erst erscheinen'
  end

  # --- Der gewollte Weg -----------------------------------------------------

  test 'SBK löscht eine erteilte Lizenz mit Begründung' do
    license_id = approved_license
    sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    login_as(sbk)

    delete_license(license_id, reason: 'Verein hat den Antrag zurückgezogen (Mail vom 03.09.)')

    assert_response :ok
    entry = current_entry
    assert_equal License::DELETED, entry['license_status_id'].to_i
    assert_equal 'Verein hat den Antrag zurückgezogen (Mail vom 03.09.)', entry['reason']
    assert_equal sbk.id, entry['created_by']
  end

  test 'auch eine beantragte Lizenz lässt sich löschen' do
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id,
                                 'history' => [{ 'license_status_id' => License::REQUESTED,
                                                 'created_at' => 1.day.ago.iso8601 }] }])
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(id)

    assert_response :ok
    assert_equal License::DELETED, current_entry['license_status_id'].to_i
  end

  # Die frühere Erteilung bleibt in der History stehen. Daran hängt die
  # Gebührenrechnung, die jede Lizenz der Saison mitsamt Verlauf exportiert:
  # Löschen darf kein Weg an der Gebühr vorbei sein.
  test 'Löschen hängt an, überschreibt nichts' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(license_id)

    history = @player.reload.licenses.first['history']
    assert_equal 3, history.size
    assert_equal([License::REQUESTED, License::APPROVED, License::DELETED],
                 history.map { |h| h['license_status_id'].to_i })
  end

  # --- Die Pflicht-Begründung ----------------------------------------------

  test 'ohne Begründung wird nicht gelöscht' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(license_id, reason: '')

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # `blank?` allein liefe hier vorbei: Ein Freitext aus lauter Leerzeichen ist
  # `present?` und stünde als leere Begründung in der Abrechnung.
  test 'eine Begründung aus Leerzeichen zählt nicht als Begründung' do
    license_id = approved_license
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(license_id, reason: "   \n\t ")

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # --- Die Grenzen der Regel ------------------------------------------------

  test 'eine abgelehnte Lizenz lässt sich nicht löschen' do
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id,
                                 'history' => [
                                   { 'license_status_id' => License::REQUESTED,
                                     'created_at' => 3.days.ago.iso8601 },
                                   { 'license_status_id' => License::DENIED,
                                     'created_at' => 2.days.ago.iso8601 }
                                 ] }])
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(id)

    assert_response :unprocessable_entity
    assert_equal License::DENIED, current_entry['license_status_id'].to_i
  end

  test 'eine Lizenz aus einer vergangenen Saison lässt sich nicht löschen' do
    license_id = approved_license(season_id: '17')
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(license_id)

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # Der Altbestand aus dem Legacy-Import trägt gar keine season_id. Er darf
  # nicht versehentlich als "laufende Saison" durchgehen.
  test 'eine Lizenz ohne season_id lässt sich nicht löschen' do
    license_id = approved_license(season_id: nil)
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(license_id)

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # --- Wer darf --------------------------------------------------------------

  test 'SBK eines fremden Spielbetriebs darf nicht löschen' do
    license_id = approved_license
    other_go = create(:game_operation)
    login_as(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    delete_license(license_id)

    assert_response :forbidden
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  test 'der Vereinsmanager darf nicht löschen' do
    license_id = approved_license
    login_as(create(:user, :vm, club_id: @club.id))

    delete_license(license_id)

    assert_response :forbidden
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i
  end

  # --- Nebenwirkungen --------------------------------------------------------

  # Die Erst-/Zweitlizenz-Zuordnung gehört zum laufenden Wettbewerb. Bliebe sie
  # an der gelöschten Lizenz hängen, zeigte das Profil weiter das Abzeichen
  # „Erstlizenz" für eine Lizenz, die es nicht mehr gibt.
  test 'die Erst-/Zweitlizenz-Zuordnung wird beim Löschen abgeräumt' do
    license_id = approved_license(extra: { 'gf_role' => 'erstlizenz' })
    login_as(create(:user, :sbk_scoped, game_operation_id: @game_operation.id))

    delete_license(license_id)

    assert_response :ok
    license = @player.reload.licenses.first
    assert_nil license['gf_role']
    assert_equal 'license_deleted', license['gf_role_history'].last['source'],
                 'der Verlauf der Zuordnung muss die Abräumung festhalten'
  end

  # --- Der abgeschaffte Weg --------------------------------------------------

  # „Für Transfer ungültig setzen" ist entfallen. Den Status setzt seither
  # ausschließlich TransferRequest#invalidate_licenses! beim Vollzug.
  test 'auch der Admin setzt den Status TRANSFER nicht mehr von Hand' do
    license_id = approved_license
    login_as(create(:user, :admin))

    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: License::TRANSFER,
                   reason: 'für Transfer ungültig gesetzt' },
         as: :json

    assert_response :unprocessable_entity
    assert_equal License::APPROVED, current_entry['license_status_id'].to_i,
                 'der Status darf sich über diesen Endpunkt nicht mehr auf TRANSFER ändern'
  end
end
