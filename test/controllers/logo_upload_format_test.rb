require 'test_helper'

# Formatprüfung der Bild-Uploads. logo_upload_error ist der gemeinsame Helfer
# aller sieben Upload-Strecken (Verein, Mannschaft, Liga-Logo, Liga-Banner,
# Spielbetriebs-Banner, Verbandslogo, Verbandsbanner), deshalb ein eigener Test
# über alle statt je einer im Test des betreffenden Controllers.
#
# Der Befund: Geprüft wurde die Formatangabe aus dem Multipart-Kopf, also das,
# was der hochladende Browser behauptet. Eine SVG als image/png deklariert kam
# damit durch, wurde von vips anstandslos gelesen (der Bild-Check greift also
# auch nicht) und landete in der Ablage, wo ActiveStorage ihren Typ selbst neu
# bestimmte. Der Kommentar über LOGO_ALLOWED_CONTENT_TYPES schließt SVG
# ausdrücklich aus; diese Zusage hielt nicht.
class LogoUploadFormatTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    # Keine Bundesliga: für die greift beim Logo eine zweite, strengere Hürde.
    @league = create(:league, game_operation: @go, league_class_id: 'rl')
    @club = create(:club, game_operation: @go)
    @team = create(:team, league: @league, club: @club)
    login(create(:user, :admin))
  end

  teardown do
    @tempfiles&.each(&:close!)
  end

  # Alle sieben Strecken mit ihrem jeweiligen Parameternamen. Quadratzwang gilt
  # nur für Vereins- und Mannschaftslogos, deshalb liefert upload/1 quadratisch.
  def endpoints
    [
      ['Vereinslogo',        "/api/v2/admin/clubs/#{@club.id}/upload_logo",                       :logo],
      ['Mannschaftslogo',    "/api/v2/admin/teams/#{@team.id}/upload_logo",                       :logo],
      ['Liga-Logo',          "/api/v2/admin/leagues/#{@league.id}/upload_logo",                   :logo],
      ['Liga-Banner',        "/api/v2/admin/leagues/#{@league.id}/upload_banner",                 :banner],
      ['Spielbetriebs-Banner', "/api/v2/admin/game_operations/#{@go.id}/upload_banner",           :banner],
      ['Verbandslogo',       "/api/v2/admin/state_associations/#{@sa.id}/upload_logo",            :logo],
      ['Verbandsbanner',     "/api/v2/admin/state_associations/#{@sa.id}/upload_banner",          :banner]
    ]
  end

  test 'eine als PNG deklarierte SVG wird auf allen sieben Strecken abgewiesen' do
    endpoints.each do |name, path, param|
      post path, params: { param => disguised_svg }

      assert_response :unprocessable_entity, "#{name}: getarnte SVG muss abgewiesen werden"
      # Eigene Meldung, nicht die der Kopfzeilen-Prüfung: Die Datei heißt .png,
      # der Hinweis muss also am Inhalt ansetzen und nicht die erlaubten
      # Endungen aufzählen, die der Aufrufer scheinbar eingehalten hat.
      #
      # Zwei Formulierungen sind zulässig, weil die SVG seit Rails 7.2.3.2 gar
      # nicht mehr bis zur Loader-Prüfung kommt: ActiveStorage sperrt beim Laden
      # die unsicheren vips-Loader (svgload gehört dazu), das Lesen scheitert
      # also schon vorher. Abgewiesen wird sie in beiden Fällen, und beide
      # Meldungen benennen den Inhalt.
      assert_match(/Inhalt der Datei passt nicht|nicht als Bild gelesen werden/,
                   JSON.parse(response.body)['message'].to_s,
                   "#{name}: die Meldung muss den Inhalt benennen, nicht die Endung")
    end

    assert_not @club.reload.logo.attached?
    assert_not @team.reload.logo.attached?
    assert_not @league.reload.logo.attached?
    assert_not @league.reload.banner.attached?
    assert_not @go.reload.banner.attached?
    assert_not @sa.reload.logo.attached?
    assert_not @sa.reload.banner.attached?
  end

  test 'eine als PNG deklarierte GIF wird abgewiesen' do
    endpoints.each do |name, path, param|
      post path, params: { param => disguised_gif }

      assert_response :unprocessable_entity, "#{name}: getarnte GIF muss abgewiesen werden"
    end
  end

  # Gegenrichtung: Die Verschärfung darf keine der drei zugesagten Formate
  # abweisen. Ohne diesen Fall wäre eine zu enge Loader-Liste (etwa ein Abbild
  # mit libspng, das pngload durch spngload ersetzt) nicht zu bemerken.
  test 'echte PNG, JPG und WebP gehen auf allen sieben Strecken durch' do
    { 'image/png' => '.png', 'image/jpeg' => '.jpg', 'image/webp' => '.webp' }.each do |type, ext|
      endpoints.each do |name, path, param|
        post path, params: { param => real_image(ext, type) }

        assert_response :success, "#{name}: #{type} muss erlaubt bleiben"
      end
    end

    assert @club.reload.logo.attached?
    assert @sa.reload.banner.attached?
  end

  # Die Prüfung muss am INHALT hängen, nicht an der Dateiendung: In Produktion
  # liegt der Upload in einer Tempdatei von Rack, die die Endung des Originals
  # nicht zwingend trägt. Liefe die Erkennung über den Namen, wäre der Riegel
  # dort wirkungslos und alle Fälle oben trotzdem grün, weil ihre Tempdateien
  # eine Endung haben.
  test 'erkannt wird am Inhalt, auch ohne Dateiendung' do
    real_without_extension = upload_from(
      Vips::Image.black(40, 40).add(128).cast('uchar').write_to_buffer('.png'), '', 'image/png'
    )
    post "/api/v2/admin/clubs/#{@club.id}/upload_logo", params: { logo: real_without_extension }
    assert_response :success, 'ein echtes PNG ohne Endung muss durchgehen'

    svg_without_extension = upload_from(
      '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><rect width="40" height="40"/></svg>',
      '', 'image/png'
    )
    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: svg_without_extension }
    assert_response :unprocessable_entity, 'eine SVG ohne Endung muss abgewiesen werden'
    assert_not @team.reload.logo.attached?
  end

  private

  def disguised_svg
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">' \
          '<script>alert(1)</script><rect width="40" height="40"/></svg>'
    upload_from(svg, '.png', 'image/png')
  end

  def disguised_gif
    upload_from(Base64.decode64('R0lGODdhAQABAIAAAAAAAAAAACwAAAAAAQABAAACAkQBADs='), '.png', 'image/png')
  end

  # Quadratisch, weil Vereins- und Mannschaftslogos das verlangen und dieselbe
  # Datei über alle sieben Strecken geht.
  def real_image(ext, content_type)
    tempfile = tempfile_for(ext)
    Vips::Image.black(40, 40).add(128).cast('uchar').write_to_file(tempfile.path)
    Rack::Test::UploadedFile.new(tempfile.path, content_type)
  end

  def upload_from(content, ext, content_type)
    tempfile = tempfile_for(ext)
    File.binwrite(tempfile.path, content)
    Rack::Test::UploadedFile.new(tempfile.path, content_type)
  end

  # Die Tempfile-Referenz muss leben bleiben: Wird sie eingesammelt, ist die
  # Datei weg, bevor der Controller sie liest.
  def tempfile_for(ext)
    @tempfiles ||= []
    tempfile = Tempfile.new(['upload', ext])
    @tempfiles << tempfile
    tempfile
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
