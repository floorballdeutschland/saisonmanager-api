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
  def upload(token: nil)
    headers = token ? { 'X-Secretary-Token' => token } : {}
    post "/api/v2/user/games/#{@game.id}/scan",
         params: { file: fixture_file_upload('dokument.pdf', 'application/pdf') },
         headers: headers
  end
end
