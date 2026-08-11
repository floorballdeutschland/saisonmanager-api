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

  # ACHTUNG: Das prueft nur die FORMATANGABE, nicht den Inhalt. Eine als image/png
  # deklarierte SVG kommt weiterhin durch (nachgestellt, HTTP 201), das sitzt im
  # gemeinsamen logo_upload_error und ist als #373 erfasst. Der Testname sagte
  # vorher "SVG wird abgewiesen" und las sich damit als Nachweis, der er nicht ist.
  test 'eine als SVG deklarierte Datei wird an der Formatangabe abgewiesen' do
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
    @club.sponsor_logos.attach(sponsor_file(width: 300, height: 80))

    _link, token = GameDayOverlayLink.generate!(game_day: game_day, created_by: @admin)
    get '/api/v2/public/overlay/live', params: { token: token, game_id: game.id }

    assert_response :success
    sponsors = JSON.parse(response.body)['game']['sponsors']
    # Zusicherung auf die konkreten Adressen und nicht auf die Anzahl: Mit
    # `size == 1` auf beiden Seiten waere ein Vertauschen der beiden Schluessel
    # unsichtbar geblieben. Genau das soll die Trennung verhindern, denn die Ebenen
    # gehoeren verschiedenen Rechteinhabern und werden auf der Buehne
    # unterschiedlich beschriftet. Die Adressen tragen die signed_id des jeweiligen
    # Anhangs, sind also eindeutig je Ebene.
    assert_equal @league.sponsor_logo_urls, sponsors['league']
    assert_equal @club.sponsor_logo_urls, sponsors['club']
    assert_not_equal sponsors['league'], sponsors['club'], 'die beiden Ebenen muessen unterscheidbar sein'
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

  # Bisher war der einzige abgewiesene Fall ein Vereinsmanager, dessen SBK- und
  # Admin-Listen ohnehin leer sind. Der Schnitt `[0, game_operation_id] & ph[:sbk]`
  # in user_permissions lief damit nur in der durchlassenden Richtung. Ein SBK
  # eines FREMDEN Spielbetriebs ist der Fall, der die Grenze zeigt.
  test 'ein SBK eines fremden Spielbetriebs darf nichts anfassen' do
    fremder_go = create(:game_operation)
    fremd_sbk = create(:user, :sbk_scoped, game_operation_id: fremder_go.id)
    login_as(fremd_sbk)

    post "/api/v2/admin/leagues/#{@league.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :forbidden

    post "/api/v2/admin/clubs/#{@club.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :forbidden

    assert_equal 0, @league.reload.sponsor_logos.count
    assert_equal 0, @club.reload.sponsor_logos.count
  end

  # Auf der Vereinsebene war nur die ABWEISUNG einer fremden attachment_id
  # geprueft. Ein 404 haette dort aber auch eine fehlende Route erzeugt, der Test
  # konnte "richtig abgewiesen" von "Route gibt es nicht" nicht unterscheiden.
  test 'ein Vereinsmanager entfernt ein eigenes Partnerlogo' do
    vm = create(:user, :vm, club_id: @club.id)
    login_as(vm)

    post "/api/v2/admin/clubs/#{@club.id}/sponsor_logos", params: { sponsor_logo: sponsor_file }
    assert_response :created
    logo_id = JSON.parse(response.body)['sponsor_logos'].first['id']

    get "/api/v2/admin/clubs/#{@club.id}/sponsor_logos"
    assert_response :success
    assert_equal 1, JSON.parse(response.body)['sponsor_logos'].size

    delete "/api/v2/admin/clubs/#{@club.id}/sponsor_logos/#{logo_id}"
    assert_response :success
    assert_empty JSON.parse(response.body)['sponsor_logos']
    assert_equal 0, @club.reload.sponsor_logos.count
  end

  # SPONSOR_LOGO_MAX_SIZE wird als Schluesselwort ueber einen Standard von
  # LOGO_MAX_SIZE (3 MB) gelegt. Faellt das `max_size:` weg, verdreifacht sich die
  # Grenze still -- kein bisheriger Testkandidat kam auch nur in die Naehe von 1 MB.
  test 'eine Datei ueber einem Megabyte wird abgewiesen' do
    login_as(@admin)
    require 'vips'
    path = Rails.root.join('tmp', 'sponsor-riesig.png')
    # Rauschen statt Schwarz: eine schwarze Flaeche komprimiert auf wenige Kilobyte.
    Vips::Image.gaussnoise(1400, 1400).pngsave(path.to_s, compression: 0)
    assert File.size(path) > SponsorLogoManagement::SPONSOR_LOGO_MAX_SIZE,
           "Testdatei ist nur #{File.size(path)} Byte gross, das prueft nichts"

    post "/api/v2/admin/leagues/#{@league.id}/sponsor_logos",
         params: { sponsor_logo: Rack::Test::UploadedFile.new(path.to_s, 'image/png') }

    assert_response :unprocessable_entity
    assert_match(/zu groß/, JSON.parse(response.body)['message'])
    assert_equal 0, @league.reload.sponsor_logos.count
  end

  # Die drei Liga-Aktionen stehen in COOKIE_ONLY_ACTIONS, damit authenticate_user
  # laeuft und authenticate_public_request NICHT. Diese Liste ist handgepflegt und
  # wirkt durch Auslassung: Faellt ein Eintrag bei einem Umbau heraus, genuegte
  # ploetzlich ein X-Api-Key. Ohne CI an diesem PR ist dieser Test der einzige
  # Waechter.
  test 'ein X-Api-Key ohne Anmeldung reicht fuer Partnerlogos nicht' do
    klartext, _api_key = ApiKey.generate(name: 'Overlay-Test')

    get "/api/v2/admin/leagues/#{@league.id}/sponsor_logos", headers: { 'X-Api-Key' => klartext }
    assert_response :unauthorized

    get "/api/v2/admin/clubs/#{@club.id}/sponsor_logos", headers: { 'X-Api-Key' => klartext }
    assert_response :unauthorized
  end
end
