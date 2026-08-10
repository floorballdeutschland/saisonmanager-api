require 'test_helper'

# Partnerlogos für die Livestream-Overlays, zwei Ebenen: der Verband pflegt die
# der Liga, der Verein die seines Vereins. Beide Ebenen müssen sich gleich
# verhalten, deshalb laufen dieselben Fälle über beide Wege.
class SponsorLogosTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation)
    @league = create(:league, game_operation: @go)
    @club = create(:club, game_operations_hash: [{ 'game_operation_id' => @go.id, 'home_game_operation' => true }])
    @admin = create(:user, :admin)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  # Ein echtes PNG, damit die Bildprüfung (libvips) etwas zu lesen bekommt.
  # Bewusst nicht quadratisch: Ein Partnerlogo ist meist ein Schriftzug, und
  # genau dafür ist die Quadrat-Prüfung der Vereinslogos hier abgeschaltet.
  def sponsor_file(width: 400, height: 100)
    require 'vips'
    path = Rails.root.join('tmp', "sponsor-#{width}x#{height}.png")
    Vips::Image.black(width, height).pngsave(path.to_s)
    Rack::Test::UploadedFile.new(path.to_s, 'image/png')
  end

  test 'Verband laedt ein Partnerlogo an der Liga hoch und entfernt es wieder' do
    login_as(@admin)

    post "/api/v2/admin/leagues/#{@league.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :created
    logos = JSON.parse(response.body)['sponsor_logos']
    assert_equal 1, logos.size
    assert logos.first['url'].present?

    get "/api/v2/admin/leagues/#{@league.id}/sponsor_logos"
    assert_response :success
    assert_equal 1, JSON.parse(response.body)['sponsor_logos'].size

    delete "/api/v2/admin/leagues/#{@league.id}/sponsor_logos/#{logos.first['id']}"
    assert_response :success
    assert_empty JSON.parse(response.body)['sponsor_logos']
  end

  test 'Verein laedt ein Partnerlogo an seinem Verein hoch' do
    login_as(@admin)

    post "/api/v2/admin/clubs/#{@club.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :created
    assert_equal 1, JSON.parse(response.body)['sponsor_logos'].size
  end

  test 'ein Vereinsmanager darf die Partner seines eigenen Vereins pflegen' do
    vm = create(:user, :vm, club_id: @club.id)
    login_as(vm)

    post "/api/v2/admin/clubs/#{@club.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :created
  end

  test 'ein Vereinsmanager darf weder fremde Vereine noch die Liga anfassen' do
    fremder = create(:club)
    vm = create(:user, :vm, club_id: fremder.id)
    login_as(vm)

    post "/api/v2/admin/clubs/#{@club.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :forbidden

    post "/api/v2/admin/leagues/#{@league.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :forbidden
  end

  test 'ohne Anmeldung geht nichts' do
    post "/api/v2/admin/leagues/#{@league.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :unauthorized
  end

  # Ein fremdes Logo darf sich nicht über eine geratene attachment_id löschen
  # lassen. Gesucht wird deshalb in den Anhaengen DIESES Objekts und nicht
  # global.
  test 'eine fremde attachment_id loescht nichts' do
    fremder = create(:club)
    fremder.sponsor_logos.attach(sponsor_file)
    fremd_id = fremder.sponsor_logos.first.id

    login_as(create(:user, :vm, club_id: @club.id))
    delete "/api/v2/admin/clubs/#{@club.id}/sponsor_logos/#{fremd_id}"

    assert_response :not_found
    assert_equal 1, fremder.reload.sponsor_logos.count
  end

  test 'SVG und andere Formate werden abgewiesen' do
    login_as(@admin)
    path = Rails.root.join('tmp', 'sponsor.svg')
    File.write(path, '<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>')

    post "/api/v2/admin/leagues/#{@league.id}/sponsor_logos",
         params: { sponsor_logo: Rack::Test::UploadedFile.new(path.to_s, 'image/svg+xml') }

    assert_response :unprocessable_entity
    assert_match(/Dateiformat/, JSON.parse(response.body)['message'])
    assert_equal 0, @league.reload.sponsor_logos.count
  end

  test 'ueber der Obergrenze wird abgewiesen statt still zu schlucken' do
    login_as(@admin)
    SponsorLogos::MAX_SPONSOR_LOGOS.times { @league.sponsor_logos.attach(sponsor_file) }

    post "/api/v2/admin/leagues/#{@league.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }

    assert_response :unprocessable_entity
    assert_equal SponsorLogos::MAX_SPONSOR_LOGOS, @league.reload.sponsor_logos.count
  end

  # Auf der Bühne laufen beide Sätze reihum durch dieselbe Fläche, sie müssen
  # dafür aber getrennt ankommen: Die Beschriftung unterscheidet sich.
  test 'der Overlay-Abruf liefert beide Ebenen getrennt' do
    game_day = create(:game_day, league: @league, club: @club)
    game = create(:game, game_day: game_day,
                         home_team: create(:team, league: @league),
                         guest_team: create(:team, league: @league))
    @league.sponsor_logos.attach(sponsor_file)
    @club.sponsor_logos.attach(sponsor_file)

    _link, token = GameDayOverlayLink.generate!(game_day: game_day, created_by: @admin)
    get '/api/v2/public/overlay/live', params: { token: token, game_id: game.id }

    assert_response :success
    sponsors = JSON.parse(response.body)['game']['sponsors']
    assert_equal 1, sponsors['league'].size
    assert_equal 1, sponsors['club'].size
  end

  test 'ohne hinterlegte Partner bleiben beide Listen leer statt zu fehlen' do
    game_day = create(:game_day, league: @league, club: nil)
    game = create(:game, game_day: game_day,
                         home_team: create(:team, league: @league),
                         guest_team: create(:team, league: @league))

    _link, token = GameDayOverlayLink.generate!(game_day: game_day, created_by: @admin)
    get '/api/v2/public/overlay/live', params: { token: token, game_id: game.id }

    assert_response :success
    sponsors = JSON.parse(response.body)['game']['sponsors']
    assert_equal [], sponsors['league']
    assert_equal [], sponsors['club']
  end
end
