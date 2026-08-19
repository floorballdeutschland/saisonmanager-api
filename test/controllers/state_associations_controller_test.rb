require 'test_helper'

# Absicherung der LV-Schreib-Autorisierung (StateAssociationWritable):
# globaler Admin darf jeden LV bearbeiten, SBK nur den eigenen (gescopten),
# RSK gar nicht. Deckt den `update`-Pfad ab; Releases- und Checklist-Controller
# nutzen dieselbe Concern und werden exemplarisch über Releases mitgeprüft.
class StateAssociationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @own_sa = StateAssociation.create!(name: "Eigener LV #{SecureRandom.hex(4)}", short_name: 'ELV')
    @own_go = GameOperation.create!(name: 'SBK Eigen', short_name: 'SBE',
                                    path: "sbk-eigen-#{SecureRandom.hex(4)}", state_association: @own_sa)
    @foreign_sa = StateAssociation.create!(name: "Fremder LV #{SecureRandom.hex(4)}", short_name: 'FLV')

    @admin = create_user(user_group_id: 1, game_operation_id: @own_go.id)
    @sbk = create_user(user_group_id: 2, game_operation_id: @own_go.id)
    @rsk = create_user(user_group_id: 3, game_operation_id: @own_go.id)
  end

  test 'Admin darf jeden Landesverband bearbeiten' do
    login(@admin)
    put "/api/v2/admin/state_associations/#{@foreign_sa.id}",
        params: { state_association: { name: 'Neu durch Admin' } }
    assert_response :success
  end

  test 'SBK darf den eigenen Landesverband bearbeiten' do
    login(@sbk)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'Neu durch SBK' } }
    assert_response :success
    assert_equal 'Neu durch SBK', @own_sa.reload.name
  end

  test 'SBK darf einen fremden Landesverband NICHT bearbeiten' do
    login(@sbk)
    put "/api/v2/admin/state_associations/#{@foreign_sa.id}",
        params: { state_association: { name: 'Übergriff' } }
    assert_response :forbidden
  end

  test 'SBK kann den übergeordneten Verband nicht ändern' do
    other_root = StateAssociation.create!(name: "Root #{SecureRandom.hex(4)}", short_name: 'RT')
    login(@sbk)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', parent_id: other_root.id } }
    assert_response :success
    assert_nil @own_sa.reload.parent_id
  end

  test 'Admin pflegt die Bundeslaender des Zustaendigkeitsbereichs' do
    login(@admin)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', states: %w[de-NI de-hb de-ni] } }

    assert_response :success
    # Normalisiert: kleingeschrieben, entdoppelt, sortiert.
    assert_equal %w[de-hb de-ni], @own_sa.reload.states
  end

  test 'Bundeslaender lassen sich wieder leeren' do
    # So sendet die Maske: JSON mit einem echten leeren Array.
    @own_sa.update!(states: %w[de-ni])
    login(@admin)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', states: [] } }, as: :json

    assert_response :success
    assert_equal [], @own_sa.reload.states
  end

  test 'Leerer String im Bereich zaehlt als kein Bundesland' do
    # Formular-kodierte Aufrufer koennen ein leeres Array nicht ausdruecken und
    # muessen einen leeren String schicken. Ohne das Filtern meldete die
    # Validierung ein unbekanntes Bundesland ohne Namen.
    @own_sa.update!(states: %w[de-ni])
    login(@admin)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', states: [''] } }

    assert_response :success
    assert_equal [], @own_sa.reload.states
  end

  test 'Unbekanntes Bundesland wird abgewiesen' do
    login(@admin)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', states: %w[de-xx] } }

    assert_response :unprocessable_entity
    assert_equal [], @own_sa.reload.states
  end

  test 'SBK kann den eigenen Zustaendigkeitsbereich weder ausweiten noch leeren' do
    # An den Bundeslaendern haengt ab #468 der Zugriff auf Spielorte. Duerfte der
    # regionale SBK sein eigenes Feld pflegen, koennte er sich fremde
    # Bundeslaender eintragen und damit Spielorte anderer Verbaende loeschen.
    #
    # Die zweite Richtung ist der wahrscheinlichere Unfall: Die Maske sendet
    # `states` bedingungslos mit, auch dem SBK, dem das Feld gar nicht angezeigt
    # wird. Ein stilles Leeren erzeugt keine Fehlermeldung, an der es auffiele.
    @own_sa.update!(states: %w[de-ni])
    login(@sbk)

    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', states: %w[de-nw] } }
    assert_response :success
    assert_equal %w[de-ni], @own_sa.reload.states

    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'X', states: [] } }, as: :json
    assert_response :success
    assert_equal %w[de-ni], @own_sa.reload.states
  end

  test 'SBK kann keinen Landesverband mit eigenem Zustaendigkeitsbereich anlegen' do
    # Beim Anlegen traegt nicht der permit-Filter, sondern authorize_admin!.
    # Faellt diese Zeile einmal ("SBK darf eigene Untergliederungen anlegen"),
    # legt sich jeder SBK einen LV mit selbst gewaehltem Bereich an und hat ab
    # #468 Loeschrechte auf fremde Spielorte. Der update-Test faengt das nicht.
    login(@sbk)
    assert_no_difference -> { StateAssociation.count } do
      post '/api/v2/admin/state_associations',
           params: { state_association: { name: 'Selbst angelegt', short_name: 'SLB', states: %w[de-nw] } }
    end

    assert_response :forbidden
  end

  test 'Admin legt einen Landesverband mit Zustaendigkeitsbereich an' do
    login(@admin)
    post '/api/v2/admin/state_associations',
         params: { state_association: { name: 'Neuer LV', short_name: 'NLV', states: %w[de-NW de-nw] } }

    assert_response :created
    assert_equal %w[de-nw], StateAssociation.find_by(short_name: 'NLV').states
  end

  test 'RSK hat keinen Zugriff auf die LV-Verwaltung' do
    login(@rsk)
    put "/api/v2/admin/state_associations/#{@own_sa.id}",
        params: { state_association: { name: 'RSK-Versuch' } }
    assert_response :forbidden
  end

  test 'Releases: SBK darf für den eigenen LV anlegen, RSK nicht' do
    login(@rsk)
    post "/api/v2/admin/state_associations/#{@own_sa.id}/releases",
         params: { recipient_game_operation_id: @own_go.id }
    assert_response :forbidden

    login(@sbk)
    post "/api/v2/admin/state_associations/#{@foreign_sa.id}/releases",
         params: { recipient_game_operation_id: @own_go.id }
    assert_response :forbidden
  end

  # Issue #191: full_hash filtert Releases standardmäßig auf die aktuelle
  # Saison. Mit ?season_id=… lassen sich Audit-Einträge vergangener Saisons
  # zurückblicken.
  test 'show: Releases zeigen per Default nur die aktuelle Saison, season_id öffnet vergangene' do
    create(:setting, current_season_id: '18')
    StateAssociationRelease.create!(grantor_state_association: @own_sa,
                                    recipient_game_operation: @own_go, season_id: 18)
    StateAssociationRelease.create!(grantor_state_association: @own_sa,
                                    recipient_game_operation: @own_go, season_id: 17)

    login(@admin)

    get "/api/v2/admin/state_associations/#{@own_sa.id}"
    assert_response :success
    current_season_ids = JSON.parse(response.body)['releases'].map { |r| r['season_id'] }
    assert_equal [18], current_season_ids

    get "/api/v2/admin/state_associations/#{@own_sa.id}", params: { season_id: '17' }
    assert_response :success
    past_season_ids = JSON.parse(response.body)['releases'].map { |r| r['season_id'] }
    assert_equal [17], past_season_ids
  end

  # Issue #275: Verbandslogos sollen die Landesverbände selbst pflegen. Vorher nahm
  # der Endpunkt ausschließlich WebP an, was praktisch jede Vorlage abwies.
  test 'upload_logo nimmt PNG, JPEG und WebP an' do
    login(@sbk)

    %w[png jpg webp].each do |format|
      post "/api/v2/admin/state_associations/#{@own_sa.id}/upload_logo",
           params: { logo: image_upload(240, 90, "lv_logo_#{format}", format) }
      assert_response :success, "#{format} wurde abgewiesen: #{response.body}"
    end

    assert @own_sa.reload.logo.attached?
  end

  # Gegenprobe zur Quadrat-Regel bei Vereins- und Teamlogos: Verbandslogos sind
  # Wortmarken im Querformat und dürfen genau deshalb nicht quadratisch sein müssen.
  test 'upload_logo akzeptiert ein Logo im Querformat' do
    login(@sbk)
    post "/api/v2/admin/state_associations/#{@own_sa.id}/upload_logo",
         params: { logo: image_upload(1024, 296, 'lv_wortmarke', 'png') }

    assert_response :success
    assert @own_sa.reload.logo.attached?
  end

  test 'upload_logo lehnt ein SVG weiterhin ab' do
    login(@sbk)
    path = Rails.root.join('tmp', 'lv_logo.svg').to_s
    File.write(path, '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>')

    post "/api/v2/admin/state_associations/#{@own_sa.id}/upload_logo",
         params: { logo: Rack::Test::UploadedFile.new(path, 'image/svg+xml') }

    assert_response :unprocessable_entity
    assert_match(/Dateiformat/, JSON.parse(response.body)['message'])
    assert_not @own_sa.reload.logo.attached?
  end

  test 'upload_banner meldet sein Groessenlimit lesbar statt als 0 MB' do
    login(@sbk)
    post "/api/v2/admin/state_associations/#{@own_sa.id}/upload_banner",
         params: { banner: oversized_png_upload }

    assert_response :unprocessable_entity
    message = JSON.parse(response.body)['message']
    assert_match(/500 KB/, message)
    assert_no_match(/0 MB/, message)
    assert_not @own_sa.reload.banner.attached?
  end

  test 'RSK darf kein Verbandslogo hochladen' do
    login(@rsk)
    post "/api/v2/admin/state_associations/#{@own_sa.id}/upload_logo",
         params: { logo: image_upload(240, 90, 'lv_logo_rsk', 'png') }

    assert_response :forbidden
    assert_not @own_sa.reload.logo.attached?
  end

  test 'SBK darf kein Logo bei einem fremden Landesverband hochladen' do
    login(@sbk)
    post "/api/v2/admin/state_associations/#{@foreign_sa.id}/upload_logo",
         params: { logo: image_upload(240, 90, 'lv_logo_fremd', 'png') }

    assert_response :forbidden
    assert_not @foreign_sa.reload.logo.attached?
  end

  private

  def image_upload(width, height, name, format)
    require 'vips'
    path = Rails.root.join('tmp', "#{name}.#{format}").to_s
    Vips::Image.black(width, height).write_to_file(path)
    Rack::Test::UploadedFile.new(path, Rack::Mime.mime_type(".#{format}"))
  end

  # Rauschen statt einer Flaeche: Ein einfarbiges PNG komprimiert auf wenige Kilobyte
  # und kaeme nie ueber das Bannerlimit.
  def oversized_png_upload
    require 'vips'
    path = Rails.root.join('tmp', 'lv_banner_gross.png').to_s
    Vips::Image.gaussnoise(1400, 1400).cast(:uchar).pngsave(path, compression: 0)
    Rack::Test::UploadedFile.new(path, 'image/png')
  end

  def create_user(user_group_id:, game_operation_id:)
    User.create!(
      user_name: "authuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
      teams: []
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
