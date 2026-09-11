require 'test_helper'

# Abweichende Mannschaftslogos in der Hand des Vereins.
#
# Zwei Rechte, die auseinandergehalten werden müssen: `:update_team` (Liga,
# Pokal-Ligen, Kurzname) bleibt beim Verband, `:update_team_logo` bekommt auch
# der Vereinsmanager. Der Regelfall bleibt das Vereinslogo – ohne eigenes Logo
# zeigt die Mannschaft es über Team#logo_url_fallback.
class TeamLogoVmTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, game_operation: @go)
    @team = create(:team, league: @league, club: @club, name: 'Alpha')
  end

  # --- Logo setzen -----------------------------------------------------------

  test 'VM des Vereins darf ein abweichendes Mannschaftslogo setzen' do
    login(create(:user, :vm, club_id: @club.id))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :success
    assert @team.reload.logo.attached?
  end

  test 'VM eines Verbund-Vereins darf das Logo der Verbundmannschaft setzen' do
    partner = create(:club, game_operation: @go)
    syndicate = create(:team, league: @league, club: @club, syndicate: true, syndicate_clubs: [partner.id])
    login(create(:user, :vm, club_id: partner.id))

    post "/api/v2/admin/teams/#{syndicate.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :success
    assert syndicate.reload.logo.attached?
  end

  test 'VM eines fremden Vereins darf das Logo nicht setzen' do
    login(create(:user, :vm, club_id: create(:club, game_operation: @go).id))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :forbidden
    assert_not @team.reload.logo.attached?
  end

  test 'TM der Mannschaft darf das Logo nicht setzen' do
    login(create(:user, :tm, team_id: @team.id))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :forbidden
    assert_not @team.reload.logo.attached?
  end

  test 'SBK des Spielbetriebs darf das Logo weiterhin setzen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :success
    assert @team.reload.logo.attached?
  end

  # --- Logo zurücknehmen -----------------------------------------------------

  test 'VM nimmt das abweichende Logo zurück und bekommt das Vereinslogo zurückgemeldet' do
    @club.logo.attach(io: File.open(square_png_path(90)), filename: 'club.png', content_type: 'image/png')
    @team.logo.attach(io: File.open(square_png_path(120)), filename: 'team.png', content_type: 'image/png')
    login(create(:user, :vm, club_id: @club.id))

    delete "/api/v2/admin/teams/#{@team.id}/logo"

    assert_response :success
    assert_not @team.reload.logo.attached?
    # Die Antwort trägt das Logo, das die Mannschaft ab jetzt zeigt – nicht leer.
    assert_equal @club.reload.logo_url, JSON.parse(response.body)['logo_url']
  end

  test 'TM darf das abweichende Logo nicht zurücknehmen' do
    @team.logo.attach(io: File.open(square_png_path(120)), filename: 'team.png', content_type: 'image/png')
    login(create(:user, :tm, team_id: @team.id))

    delete "/api/v2/admin/teams/#{@team.id}/logo"

    assert_response :forbidden
    assert @team.reload.logo.attached?
  end

  test 'Zurücknehmen ohne eigenes Logo bleibt erfolgreich' do
    login(create(:user, :vm, club_id: @club.id))

    delete "/api/v2/admin/teams/#{@team.id}/logo"

    assert_response :success
    assert_not @team.reload.logo.attached?
  end

  # --- Mannschaftsliste des Vereins -----------------------------------------

  test 'admin_club_teams listet dem VM die Mannschaften der laufenden Saison samt Verbundmannschaft' do
    partner = create(:club, game_operation: @go)
    syndicate = create(:team, league: @league, club: partner, name: 'Beta',
                             syndicate: true, syndicate_clubs: [@club.id])
    create(:team, league: create(:league, :previous_season, game_operation: @go), club: @club, name: 'Vorsaison')
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/clubs/#{@club.id}/teams"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [@team.id, syndicate.id].sort, body.map { |t| t['id'] }.sort
    assert(body.all? { |t| t['manage_logo'] })
  end

  test 'admin_club_teams meldet die Mannschaft ohne eigenes Logo mit dem Vereinslogo' do
    @club.logo.attach(io: File.open(square_png_path(90)), filename: 'club.png', content_type: 'image/png')
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/clubs/#{@club.id}/teams"

    assert_response :success
    team = JSON.parse(response.body).first
    assert_nil team['logo'], 'ohne eigenes Logo muss das Feld leer bleiben'
    assert_equal @club.reload.logo_url, team['logo_url']
  end

  test 'admin_club_teams verweigert dem TM und einem fremden VM die Liste' do
    login(create(:user, :tm, team_id: @team.id))
    get "/api/v2/admin/clubs/#{@club.id}/teams"
    assert_response :forbidden

    login(create(:user, :vm, club_id: create(:club, game_operation: @go).id))
    get "/api/v2/admin/clubs/#{@club.id}/teams"
    assert_response :forbidden
  end

  # Das Recht am Logo hängt am Spielbetrieb der LIGA, der Lesezugriff auf die
  # Liste am zuständigen Spielbetrieb des VEREINS. Für einen SBK laufen die
  # beiden auseinander, sobald eine Mannschaft in einer fremden Liga spielt.
  test 'admin_club_teams meldet dem SBK manage_logo false für eine Mannschaft in fremder Liga' do
    foreign_go = create(:game_operation, state_association_id: create(:state_association).id)
    foreign_team = create(:team, league: create(:league, game_operation: foreign_go), club: @club, name: 'Gast')
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/admin/clubs/#{@club.id}/teams"

    assert_response :success
    by_id = JSON.parse(response.body).index_by { |t| t['id'] }
    assert by_id[@team.id]['manage_logo']
    assert_not by_id[foreign_team.id]['manage_logo']
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def square_png_path(size)
    require 'vips'
    path = Rails.root.join('tmp', "team_logo_vm_#{size}.png").to_s
    Vips::Image.black(size, size).pngsave(path)
    path
  end

  def square_png_upload(size)
    Rack::Test::UploadedFile.new(square_png_path(size), 'image/png')
  end
end
