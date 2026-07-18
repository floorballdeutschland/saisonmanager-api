require 'test_helper'

class TeamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @team = create(:team, league: @league, club: @club, contact_email: 'team@example.org')
  end

  test 'admin_get_team erlaubt dem SBK des Spielbetriebs den Zugriff inkl. Kontaktdaten' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
    assert_equal 'team@example.org', JSON.parse(response.body)['contact_email']
  end

  test 'admin_get_team sperrt SBK eines fremden Spielbetriebs' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :forbidden
  end

  test 'admin_get_team erlaubt dem TM des Teams den Zugriff' do
    login(create(:user, :tm, team_id: @team.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
  end

  test 'admin_get_team erlaubt dem VM des Vereins den Zugriff' do
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
  end

  test 'destroy löscht ein Team ohne Spieler/Spiele als Admin' do
    login(create(:user, :admin))

    assert_difference('Team.count', -1) do
      delete "/api/v2/admin/teams/#{@team.id}"
    end

    assert_response :no_content
  end

  test 'destroy sperrt VM des Vereins (keine Löschberechtigung)' do
    login(create(:user, :vm, club_id: @club.id))

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :forbidden
    assert Team.exists?(@team.id)
  end

  test 'destroy sperrt SBK eines fremden Spielbetriebs' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :forbidden
    assert Team.exists?(@team.id)
  end

  test 'destroy erlaubt dem SBK des richtigen Spielbetriebs das Löschen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    assert_difference('Team.count', -1) do
      delete "/api/v2/admin/teams/#{@team.id}"
    end

    assert_response :no_content
  end

  test 'destroy lehnt Löschung ab, wenn noch Spieler/Lizenzen zugeordnet sind' do
    login(create(:user, :admin))
    create(:player, with_licenses: [{ team: @team }])

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Spieler/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn noch Spiele existieren' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    guest = create(:team, league: @league, club: @club)
    Game.create!(
      game_day:,
      home_team: @team,
      guest_team: guest,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Spiele/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn das Team nur als Gastteam an einem Spiel beteiligt ist' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    home = create(:team, league: @league, club: @club)
    Game.create!(
      game_day:,
      home_team: home,
      guest_team: @team,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Spiele/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn noch Sperren dem Team zugeordnet sind' do
    login(create(:user, :admin))
    player = create(:player)
    PlayerSuspension.create!(
      player:, team_id: @team.id, valid_from: '2026-01-01', valid_until: '2026-06-30'
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Sperren/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn noch Schiedsrichter-Feedback für das Team existiert' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    home = create(:team, league: @league, club: @club)
    guest = create(:team, league: @league, club: @club)
    game = Game.create!(
      game_day:,
      home_team: home,
      guest_team: guest,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
    RefereeFeedback.create!(
      game:, team: @team, line_rating: 5, communication_rating: 5
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Feedback/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'stats liefert Torschützen/Spiele auch für ein Team aus einer abgelaufenen Saison' do
    login(create(:user, :admin))
    archived_league = create(:league, :archived_season, game_operation: @go)
    archived_team = create(:team, league: archived_league, club: @club)
    guest = create(:team, league: archived_league, club: @club)
    arena = create(:arena)
    game_day = GameDay.create!(league: archived_league, arena:, club: @club, number: 1, date: '2003-01-01')
    Game.create!(
      game_day:,
      home_team: archived_team,
      guest_team: guest,
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )

    get "/api/v2/teams/#{archived_team.id}/stats"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal archived_league.id, body['team']['league_id']
    assert_equal 1, body['recent_games'].length
  end

  test 'destroy lehnt Löschung mit 422 ab, wenn eine Spieltag-Bestätigung existiert (DB-FK)' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    GameDayTeamConfirmation.create!(game_day:, team: @team, confirmed_at: Time.current)

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/verknüpfte Einträge/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'admin_upload_logo akzeptiert ein quadratisches PNG' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :success
    assert @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt ein nicht-quadratisches Bild mit 422 ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: png_upload(200, 100, 'wide') }

    assert_response :unprocessable_entity
    assert_match(/quadratisch/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt ein unzulässiges Format mit 422 ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo",
         params: { logo: Rack::Test::UploadedFile.new(gif_path, 'image/gif') }

    assert_response :unprocessable_entity
    assert_match(/Dateiformat/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt SVG mit 422 ab (nur Raster-Formate erlaubt)' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo",
         params: { logo: Rack::Test::UploadedFile.new(svg_path, 'image/svg+xml') }

    assert_response :unprocessable_entity
    assert_match(/Dateiformat/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt eine zu große Datei mit 422 ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: oversized_png_upload }

    assert_response :unprocessable_entity
    assert_match(/zu groß/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt einen Nicht-Datei-Parameter mit 422 (statt 500) ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: 'kein-bild' }

    assert_response :unprocessable_entity
    assert_not @team.reload.logo.attached?
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def square_png_upload(size)
    png_upload(size, size, "square#{size}")
  end

  def png_upload(width, height, name)
    require 'vips'
    path = Rails.root.join('tmp', "logo_test_#{name}.png").to_s
    Vips::Image.black(width, height).pngsave(path)
    Rack::Test::UploadedFile.new(path, 'image/png')
  end

  def gif_path
    path = Rails.root.join('tmp', 'logo_test.gif').to_s
    # Kleinstmögliches GIF (nur der Header zählt, geprüft wird ausschließlich der content_type).
    File.binwrite(path, "GIF89a\x01\x00\x01\x00\x00\x00\x00;")
    path
  end

  def svg_path
    path = Rails.root.join('tmp', 'logo_test.svg').to_s
    File.write(path, '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>')
    path
  end

  def oversized_png_upload
    path = Rails.root.join('tmp', 'logo_test_big.png').to_s
    File.binwrite(path, "\x00" * (3.megabytes + 1))
    Rack::Test::UploadedFile.new(path, 'image/png')
  end
end
