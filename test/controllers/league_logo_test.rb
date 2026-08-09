require 'test_helper'

# Logo der Liga, das Erkennungszeichen des Wettbewerbs. Zwei Dinge sind hier
# festzuhalten: die Rechteprüfung am Hochladen und die Rückfallkette auf den
# Landesverband, wenn eine Liga kein eigenes Zeichen hat.
class LeagueLogoTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    # Ausdruecklich keine Bundesliga: Die Fabrik setzt league_class_id auf
    # '1fbl', und fuer Bundesligen greift eine zweite, strengere Huerde
    # (buli_ok?). Ohne diese Zeile pruefen die Rechte-Tests unten diese Huerde
    # statt der Rechtepruefung, die sie pruefen sollen.
    @league = create(:league, game_operation: @go, league_class_id: 'rl')
  end

  def png_upload(width = 300, height = 120, name = 'logo')
    @uploads ||= []
    file = Tempfile.new([name, '.png'])
    @uploads << file
    # Kleines, gültiges PNG in der gewünschten Größe: logo_upload_error liest
    # die Datei mit Vips, ein Platzhalter-String käme dort nicht durch.
    image = Vips::Image.black(width, height).add(128).cast('uchar')
    image.write_to_file(file.path)
    Rack::Test::UploadedFile.new(file.path, 'image/png')
  end

  # ── Rückfallkette ─────────────────────────────────────────────────────────

  test 'ohne eigenes Logo nennt die Liga das des Landesverbands' do
    @sa.logo.attach(io: File.open(fixture_png), filename: 'sa.png', content_type: 'image/png')

    resolved = @league.reload.resolved_logo

    assert_equal 'state_association', resolved[:logo_source]
    assert resolved[:logo_url].present?
  end

  test 'ein eigenes Logo geht dem des Landesverbands vor' do
    @sa.logo.attach(io: File.open(fixture_png), filename: 'sa.png', content_type: 'image/png')
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')

    assert_equal 'league', @league.reload.resolved_logo[:logo_source]
  end

  test 'ohne jedes Logo bleibt die Herkunft leer' do
    resolved = @league.resolved_logo

    assert_nil resolved[:logo_url]
    assert_nil resolved[:logo_source]
  end

  test 'die Liga-Daten nennen Logo und Herkunft' do
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')

    hash = @league.reload.full_hash

    assert hash[:logo_url].present?
    assert_equal 'league', hash[:logo_source]
  end

  # ── Hochladen ─────────────────────────────────────────────────────────────

  test 'Admin kann ein Logo hochladen' do
    login(create(:user, :admin))

    post "/api/v2/admin/leagues/#{@league.id}/upload_logo", params: { logo: png_upload }

    assert_response :success
    assert @league.reload.logo.attached?
  end

  test 'Querformat ist erlaubt, anders als bei Vereinslogos' do
    login(create(:user, :admin))

    post "/api/v2/admin/leagues/#{@league.id}/upload_logo", params: { logo: png_upload(600, 200) }

    assert_response :success
  end

  test 'ohne Anmeldung geht kein Upload' do
    post "/api/v2/admin/leagues/#{@league.id}/upload_logo", params: { logo: png_upload }

    assert_response :unauthorized
    assert_not @league.reload.logo.attached?
  end

  # Der Controller ist für die Öffentlichkeit geöffnet und nimmt sonst einen
  # blossen API-Schlüssel. Ohne Eintrag in COOKIE_ONLY_ACTIONS könnte damit
  # jeder Schlüsselinhaber Liga-Logos austauschen.
  test 'ein API-Schluessel allein reicht nicht zum Hochladen' do
    raw_key, = ApiKey.generate(name: 'Fremdzugang')

    post "/api/v2/admin/leagues/#{@league.id}/upload_logo",
         params: { logo: png_upload }, headers: { 'HTTP_X_API_KEY' => raw_key }

    assert_response :unauthorized
    assert_not @league.reload.logo.attached?
  end

  test 'SBK eines fremden Spielbetriebs darf nicht' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    post "/api/v2/admin/leagues/#{@league.id}/upload_logo", params: { logo: png_upload }

    assert_response :forbidden
  end

  test 'eine unbrauchbare Datei wird abgewiesen' do
    login(create(:user, :admin))

    post "/api/v2/admin/leagues/#{@league.id}/upload_logo",
         params: { logo: Rack::Test::UploadedFile.new(StringIO.new('kein Bild'), 'image/png', original_filename: 'x.png') }

    assert_response :unprocessable_entity
    assert_not @league.reload.logo.attached?
  end

  # ── Zwischenspeicher ──────────────────────────────────────────────────────
  #
  # /api/v2/init gibt je Spielbetrieb bis zu fuenf Ligen samt Logo aus und steht
  # eine halbe Stunde. Ohne Verwerfen bliebe ein frisches Zeichen so lange
  # unsichtbar. Im Test steht sonst der :null_store, deshalb hier ein echter.

  test 'ein neues Logo verwirft den Eintrag von init' do
    with_memory_cache do
      Rails.cache.write('settings/init', 'alt')
      login(create(:user, :admin))

      post "/api/v2/admin/leagues/#{@league.id}/upload_logo", params: { logo: png_upload }

      assert_response :success
      assert_nil Rails.cache.read('settings/init')
    end
  end

  test 'ein geloeschtes Logo verwirft den Eintrag von init' do
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')
    with_memory_cache do
      Rails.cache.write('settings/init', 'alt')
      login(create(:user, :admin))

      delete "/api/v2/admin/leagues/#{@league.id}/logo"

      assert_response :success
      assert_nil Rails.cache.read('settings/init')
    end
  end

  # ── Loeschen ──────────────────────────────────────────────────────────────
  #
  # Eigene Faelle, obwohl das Hochladen dieselbe Pruefung hat: Ein Mutationslauf
  # (Rechtepruefung in admin_delete_logo gestrichen) blieb gruen. Ohne diese
  # Tests duerfte danach jeder Angemeldete das Zeichen jeder Liga entfernen.

  test 'ohne Anmeldung geht kein Loeschen' do
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')

    delete "/api/v2/admin/leagues/#{@league.id}/logo"

    assert_response :unauthorized
    assert @league.reload.logo.attached?
  end

  test 'ein API-Schluessel allein reicht nicht zum Loeschen' do
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')
    raw_key, = ApiKey.generate(name: 'Fremdzugang')

    delete "/api/v2/admin/leagues/#{@league.id}/logo", headers: { 'HTTP_X_API_KEY' => raw_key }

    assert_response :unauthorized
    assert @league.reload.logo.attached?
  end

  test 'ein Teammanager darf kein Liga-Logo loeschen' do
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')
    team = create(:team, league: @league)
    login(create(:user, :tm, team_id: team.id))

    delete "/api/v2/admin/leagues/#{@league.id}/logo"

    assert_response :forbidden
    assert @league.reload.logo.attached?
  end

  test 'SBK eines fremden Spielbetriebs darf nicht loeschen' do
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')
    other_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    delete "/api/v2/admin/leagues/#{@league.id}/logo"

    assert_response :forbidden
    assert @league.reload.logo.attached?
  end

  # ── Bundesligen ───────────────────────────────────────────────────────────
  #
  # Wer eine Bundesliga nicht umbenennen darf, darf auch ihr Zeichen nicht
  # austauschen: Es geht bundesweit auf Sendung. Dieselbe Huerde wie in
  # admin_league_update.

  test 'ein auf seinen Spielbetrieb beschraenkter SBK darf kein Bundesliga-Logo setzen' do
    buli = create(:league, game_operation: @go, league_class_id: '1fbl')
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/admin/leagues/#{buli.id}/upload_logo", params: { logo: png_upload }

    assert_response :forbidden
    assert_not buli.reload.logo.attached?
  end

  test 'ein auf seinen Spielbetrieb beschraenkter SBK darf kein Bundesliga-Logo loeschen' do
    buli = create(:league, game_operation: @go, league_class_id: '2fbl')
    buli.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    delete "/api/v2/admin/leagues/#{buli.id}/logo"

    assert_response :forbidden
    assert buli.reload.logo.attached?
  end

  test 'ein globaler SBK darf ein Bundesliga-Logo setzen' do
    buli = create(:league, game_operation: @go, league_class_id: '1fbl')
    login(create(:user, :sbk_global))

    post "/api/v2/admin/leagues/#{buli.id}/upload_logo", params: { logo: png_upload }

    assert_response :success
    assert buli.reload.logo.attached?
  end

  test 'Loeschen faellt auf das Verbandslogo zurueck' do
    @sa.logo.attach(io: File.open(fixture_png), filename: 'sa.png', content_type: 'image/png')
    @league.logo.attach(io: File.open(fixture_png), filename: 'liga.png', content_type: 'image/png')
    login(create(:user, :admin))

    delete "/api/v2/admin/leagues/#{@league.id}/logo"

    assert_response :success
    assert_equal 'state_association', JSON.parse(response.body)['logo_source']
    assert_not @league.reload.logo.attached?
  end

  private

  def with_memory_cache
    previous = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    yield
  ensure
    Rails.cache = previous
  end

  # Die Tempfile-Referenz muss leben bleiben: Wird sie eingesammelt, ist die
  # Datei weg, bevor jemand sie liest.
  def fixture_png
    @fixture_file ||= Tempfile.new(['fixture', '.png'])
    @fixture_png ||= begin
      Vips::Image.black(120, 60).add(200).cast('uchar').write_to_file(@fixture_file.path)
      @fixture_file.path
    end
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
