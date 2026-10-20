require 'test_helper'

# Papierspielberichtsbogen: Wer ihn hochladen und ansehen darf (#613).
#
# Bis dahin waren es nur Admin, die SBK des Spielbetriebs und der
# Vereinsmanager des ausrichtenden Vereins. Die Oberfläche blendet das Feld
# aber allen ein, die den Spielbericht führen dürfen – Teammanager der
# beteiligten Mannschaften und das Spielsekretariat per Einmal-Link
# eingeschlossen.
class GameScansControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @hosting_club = create(:club, state_association_id: @sa.id)
    @guest_club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)

    @game_day = GameDay.create!(league: @league, arena: @arena, club: @hosting_club,
                                number: 1, date: '2026-01-10')
    @home = create(:team, league: @league, club: @hosting_club)
    @guest = create(:team, league: @league, club: @guest_club)
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                         forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })

    @issuer = create(:user, :admin)
    _link, @token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @issuer)
  end

  # --- Hochladen ------------------------------------------------------------

  test 'Teammanager der Gastmannschaft darf hochladen' do
    login_as(create(:user, :tm, team_id: @guest.id))

    upload

    assert_response :created
    assert @game.reload.game_scan&.scan_file&.attached?
  end

  test 'Vereinsmanager des Gastvereins darf hochladen' do
    login_as(create(:user, :vm, club_id: @guest_club.id))

    upload

    assert_response :created
  end

  test 'Spielsekretariat per Link darf ohne Anmeldung hochladen' do
    upload(token: @token)

    assert_response :created
    # Ohne Anmeldung wird der Aussteller des Links als Urheber vermerkt.
    assert_equal @issuer.id, @game.reload.game_scan.uploaded_by_id
  end

  test 'Link eines fremden Spieltags darf nicht hochladen' do
    other_day = GameDay.create!(league: @league, arena: @arena, club: @hosting_club,
                                number: 2, date: '2026-01-17')
    _link, foreign_token = GameDaySecretaryLink.generate!(game_days: [other_day], created_by: @issuer)

    upload(token: foreign_token)

    assert_response :forbidden
    assert_nil @game.reload.game_scan
  end

  test 'ohne Anmeldung und ohne Link gibt es 401' do
    upload

    assert_response :unauthorized
  end

  test 'Unbeteiligter Vereinsmanager darf nicht hochladen' do
    login_as(create(:user, :vm, club_id: create(:club, state_association_id: @sa.id).id))

    upload

    assert_response :forbidden
  end

  # --- Nur PDF -----------------------------------------------------------

  test 'Foto als Scan wird abgewiesen' do
    login_as(create(:user, :tm, team_id: @guest.id))

    upload(file: fixture_file_upload('foto.png', 'image/png'))

    assert_response :unprocessable_entity
    assert_equal ['Nur PDF-Dateien bis 5 MB sind zulässig, Fotos werden nicht angenommen.'],
                 response.parsed_body['errors']
    assert_nil @game.reload.game_scan
  end

  # Der content_type kommt aus dem Multipart-Kopf und ist frei wählbar. Ein
  # Foto erkennt ActiveStorage an seinen Magic Bytes und korrigiert den Typ
  # selbst, eine Datei ohne solche Kennung behält den angegebenen.
  test 'als PDF ausgegebene Nicht-PDF-Datei wird abgewiesen' do
    login_as(create(:user, :tm, team_id: @guest.id))

    upload(file: fixture_file_upload('notiz.txt', 'application/pdf'))

    assert_response :unprocessable_entity
    assert_nil @game.reload.game_scan
  end

  # Der alte Scan wurde vor der Prüfung gelöscht: Ein abgewiesener Upload nahm
  # den gültigen Bogen mit.
  test 'abgewiesener Upload laesst den vorhandenen Scan stehen' do
    login_as(create(:user, :tm, team_id: @guest.id))
    upload
    old_scan = @game.reload.game_scan
    old_blob_id = old_scan.scan_file.blob.id

    assert_no_enqueued_jobs(only: ActiveStorage::PurgeJob) do
      upload(file: fixture_file_upload('foto.png', 'image/png'))
    end

    assert_response :unprocessable_entity
    scan = @game.reload.game_scan
    assert_equal old_scan.id, scan.id
    assert_equal old_blob_id, scan.scan_file.blob.id
    assert ActiveStorage::Blob.exists?(old_blob_id)
  end

  test 'gueltiger Upload ersetzt den vorhandenen Scan' do
    login_as(create(:user, :tm, team_id: @guest.id))
    upload
    old_scan = @game.reload.game_scan

    upload

    assert_response :created
    assert_equal 1, GameScan.where(game_id: @game.id).count
    assert_not_equal old_scan.id, @game.reload.game_scan.id
    assert_not GameScan.exists?(old_scan.id)
  end

  # --- Lesen ----------------------------------------------------------------
  #
  # Der Lesepfad hing an derselben Prüfung. Die Berichtsansicht ruft ihn bei
  # Scan-Pflicht beim Öffnen ab, und der ErrorInterceptor wirft bei 403 auf die
  # Startseite: Ein Teammanager flog damit aus dem geöffneten Spielbericht.
  test 'Teammanager darf den Scan lesen' do
    login_as(create(:user, :tm, team_id: @home.id))

    get "/api/v2/user/games/#{@game.id}/scan"

    assert_response :success
  end

  test 'Spielsekretariat per Link darf den Scan lesen' do
    get "/api/v2/user/games/#{@game.id}/scan", headers: { 'X-Secretary-Token' => @token }

    assert_response :success
  end

  # --- Löschen --------------------------------------------------------------

  test 'Loeschen bleibt Admin und SBK vorbehalten' do
    login_as(create(:user, :admin))
    upload
    assert_response :created

    login_as(create(:user, :tm, team_id: @home.id))
    delete "/api/v2/user/games/#{@game.id}/scan"

    assert_response :forbidden
    assert @game.reload.game_scan&.scan_file&.attached?
  end

  test 'SBK des Spielbetriebs darf loeschen' do
    login_as(create(:user, :admin))
    upload

    login_as(create(:user, :sbk_scoped, game_operation_id: @go.id))
    delete "/api/v2/user/games/#{@game.id}/scan"

    assert_response :success
    assert_nil @game.reload.game_scan
  end

  private

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # Der Token kommt im Betrieb als Header, so wie ihn der
  # SecretaryTokenInterceptor anhängt.
  def upload(token: nil, file: fixture_file_upload('dokument.pdf', 'application/pdf'))
    headers = token ? { 'X-Secretary-Token' => token } : {}
    post "/api/v2/user/games/#{@game.id}/scan",
         params: { file: file },
         headers: headers
  end
end
