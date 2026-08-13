require 'test_helper'

class ClubsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
  end

  test 'admin_club_all liefert TM die schlanke Liste ohne contact_email' do
    club = create(:club, contact_email: 'geheim@example.org')
    team = create(:team, club: club)
    login(create(:user, :tm, team_id: team.id))

    get '/api/v2/admin/clubs/all'

    assert_response :success
    body = JSON.parse(response.body)
    assert(body.any? { |c| c['id'] == club.id })
    assert_not body.any? { |c| c.key?('contact_email') }, 'contact_email darf nicht enthalten sein'
  end

  test 'admin_club_all ist für reine Schiri-Logins gesperrt' do
    login(create(:user, permissions: [{ 'user_group_id' => 6 }]))

    get '/api/v2/admin/clubs/all'

    assert_response :forbidden
  end

  test 'admin_club liefert dem SBK des Spielbetriebs den vollen Datensatz' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    club = create(:club, contact_email: 'kontakt@example.org',
                         game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go.id }])
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :success
    assert_equal 'kontakt@example.org', JSON.parse(response.body)['contact_email']
  end

  # Umgekehrtes Verhalten als bis 08/2026: Ein bloßer Gast-Eintrag im
  # game_operations_hash gibt keinen Zugriff auf die Vereinsstammdaten mehr. Die
  # Einträge stammen aus dem Altdaten-Import 2010–2014, werden von der Anwendung
  # nie geschrieben und nicht nachgeführt (auf Produktion waren 188 von 220 durch
  # keine aktuelle Liga gedeckt). Der ausdrückliche Weg ist die Vereins-Freigabe,
  # siehe den folgenden Test.
  test 'admin_club sperrt SBK bei Vereinen, die nur als Gast in ihrem Spielbetrieb stehen' do
    home_sa = create(:state_association)
    home_go = create(:game_operation, state_association_id: home_sa.id)
    guest_sa = create(:state_association)
    guest_go = create(:game_operation, state_association_id: guest_sa.id)
    # Verein gehört home_go, trägt guest_go nur als Gast-Eintrag
    club = create(:club, state_association_id: home_sa.id, contact_email: 'kontakt@example.org',
                         game_operations_hash: [
                           { 'home_game_operation' => true, 'game_operation_id' => home_go.id },
                           { 'home_game_operation' => false, 'game_operation_id' => guest_go.id }
                         ])
    login(create(:user, :sbk_scoped, game_operation_id: guest_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :forbidden
  end

  # Gegenprobe: Mit Freigabe ist derselbe Zugriff erlaubt – die Freigabe ist
  # ausdrücklich erteilt, saisongebunden und über die Verbandsmaske pflegbar.
  test 'admin_club erlaubt Lesezugriff auf Gast-Verein MIT Vereins-Freigabe' do
    home_sa = create(:state_association)
    home_go = create(:game_operation, state_association_id: home_sa.id)
    guest_sa = create(:state_association)
    guest_go = create(:game_operation, state_association_id: guest_sa.id)
    club = create(:club, state_association_id: home_sa.id, contact_email: 'kontakt@example.org',
                         game_operations_hash: [
                           { 'home_game_operation' => true, 'game_operation_id' => home_go.id },
                           { 'home_game_operation' => false, 'game_operation_id' => guest_go.id }
                         ])
    StateAssociationRelease.create!(grantor_state_association_id: home_sa.id,
                                    recipient_game_operation_id: guest_go.id,
                                    season_id: Setting.current_season_id)
    login(create(:user, :sbk_scoped, game_operation_id: guest_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :success
    assert_equal 'kontakt@example.org', JSON.parse(response.body)['contact_email']
  end

  test 'admin_club ist für SBK eines fremden Spielbetriebs gesperrt' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    club = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go.id }])
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :forbidden
  end

  test 'admin_club erlaubt LV-SBK den Lesezugriff auf freigegebene Vereine' do
    grantor_sa = create(:state_association)
    grantor_go = create(:game_operation, state_association_id: grantor_sa.id)
    recipient_sa = create(:state_association)
    recipient_go = create(:game_operation, state_association_id: recipient_sa.id)
    club = create(:club, state_association_id: grantor_sa.id,
                         game_operations_hash: [{ 'home_game_operation' => true,
                                                  'game_operation_id' => grantor_go.id }])
    StateAssociationRelease.create!(
      grantor_state_association_id: grantor_sa.id,
      recipient_game_operation_id: recipient_go.id,
      season_id: Setting.current_season_id
    )
    login(create(:user, :sbk_scoped, game_operation_id: recipient_go.id))

    get "/api/v2/admin/clubs/#{club.id}"

    assert_response :success
  end

  test 'user_clubs_and_teams liefert SBK mit mehreren Spielbetrieben alle Vereine' do
    go1 = create(:game_operation)
    go2 = create(:game_operation)
    club1 = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go1.id }])
    club2 = create(:club, game_operations_hash: [{ 'home_game_operation' => true, 'game_operation_id' => go2.id }])
    login(create(:user, permissions: [
      { 'user_group_id' => 2, 'game_operation_id' => go1.id },
      { 'user_group_id' => 2, 'game_operation_id' => go2.id }
    ]))

    get '/api/v2/user/clubs_and_teams'

    assert_response :success
    ids = JSON.parse(response.body).map { |c| c['id'] }
    assert_includes ids, club1.id
    assert_includes ids, club2.id
  end

  # Ein Verein kann Teams in Ligen mehrerer Spielbetriebe haben (Gastvereine
  # anderer Landesverbände). Die Auswahl im Lizenzwesen darf dem SBK nur die
  # Teams zeigen, für die er anschließend auch etwas tun darf.
  test 'user_clubs_and_teams zeigt SBK nur Teams seines Spielbetriebs' do
    go_own = create(:game_operation)
    go_other = create(:game_operation)
    club = create(:club, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => go_own.id },
      { 'game_operation_id' => go_other.id }
    ])
    own_team = create(:team, club: club, league: create(:league, :current_season, game_operation: go_own))
    other_team = create(:team, club: club, league: create(:league, :current_season, game_operation: go_other))
    login(create(:user, :sbk_scoped, game_operation_id: go_own.id))

    get '/api/v2/user/clubs_and_teams'

    assert_response :success
    entry = JSON.parse(response.body).find { |c| c['id'] == club.id }
    assert entry, 'Verein des eigenen Spielbetriebs muss enthalten sein'
    team_ids = entry['teams'].map { |t| t['id'] }
    assert_includes team_ids, own_team.id
    assert_not_includes team_ids, other_team.id
  end

  # Kern von Teil 2: Die Vereins-Zeilen kommen nicht mehr aus dem
  # game_operations_hash, sondern aus den Mannschaften der eigenen Ligen. Ein
  # Gastverein bleibt damit erreichbar, obwohl sein Landesverband nichts
  # freigegeben hat – so behält z.B. Schleswig-Holstein die Nord-Mannschaften.
  test 'user_clubs_and_teams zeigt Gastverein mit Mannschaft in eigener Liga' do
    go_own = create(:game_operation)
    go_home = create(:game_operation)
    gast = create(:club, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => go_home.id }
    ])
    gast_team = create(:team, club: gast, league: create(:league, :current_season, game_operation: go_own))
    login(create(:user, :sbk_scoped, game_operation_id: go_own.id))

    get '/api/v2/user/clubs_and_teams'

    assert_response :success
    entry = JSON.parse(response.body).find { |c| c['id'] == gast.id }
    assert entry, 'Gastverein mit Mannschaft in der eigenen Liga muss erscheinen'
    assert_equal([gast_team.id], entry['teams'].map { |t| t['id'] })
  end

  # Gegenprobe: Der bloße Gast-Eintrag im Hash reicht nicht mehr. Genau diese
  # Altlast (183 von 220 Einträgen auf Produktion) soll wegfallen.
  test 'user_clubs_and_teams ignoriert reine Gast-Eintraege ohne Mannschaft' do
    go_own = create(:game_operation)
    go_home = create(:game_operation)
    altlast = create(:club, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => go_home.id },
      { 'home_game_operation' => false, 'game_operation_id' => go_own.id }
    ])
    login(create(:user, :sbk_scoped, game_operation_id: go_own.id))

    get '/api/v2/user/clubs_and_teams'

    assert_response :success
    assert_not_includes JSON.parse(response.body).map { |c| c['id'] }, altlast.id
  end

  # Bugfix im selben Zug: Die Aktion kannte die Vereins-Freigabe bisher gar nicht.
  test 'user_clubs_and_teams zeigt freigegebene Vereine' do
    grantor_sa = create(:state_association)
    grantor_go = create(:game_operation, state_association_id: grantor_sa.id)
    go_own = create(:game_operation)
    freigegeben = create(:club, state_association_id: grantor_sa.id, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => grantor_go.id }
    ])
    StateAssociationRelease.create!(grantor_state_association_id: grantor_sa.id,
                                    recipient_game_operation_id: go_own.id,
                                    season_id: Setting.current_season_id)
    login(create(:user, :sbk_scoped, game_operation_id: go_own.id))

    get '/api/v2/user/clubs_and_teams'

    assert_response :success
    assert_includes JSON.parse(response.body).map { |c| c['id'] }, freigegeben.id
  end

  test 'user_clubs_and_teams zeigt VM alle Teams des eigenen Vereins' do
    go_own = create(:game_operation)
    go_other = create(:game_operation)
    club = create(:club)
    team_a = create(:team, club: club, league: create(:league, :current_season, game_operation: go_own))
    team_b = create(:team, club: club, league: create(:league, :current_season, game_operation: go_other))
    login(create(:user, :vm, club_id: club.id))

    get '/api/v2/user/clubs_and_teams'

    assert_response :success
    entry = JSON.parse(response.body).find { |c| c['id'] == club.id }
    team_ids = entry['teams'].map { |t| t['id'] }
    assert_includes team_ids, team_a.id
    assert_includes team_ids, team_b.id
  end

  # Kern der Meldung: Wer neben der Vereinsrolle auch die Spielbetriebsrolle
  # hat, bekam über user_clubs_and_teams alle Vereine des Spielbetriebs und
  # damit im Portal "Meine Spieler*innen" fremde Vereine samt 403 beim Laden.
  # Das Portal fragt deshalb diese Aktion, die andere Rollen ignoriert.
  test 'vm_clubs_and_teams liefert VM mit SBK-Rolle nur den eigenen Verein' do
    go = create(:game_operation)
    eigener_club = create(:club, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => go.id }
    ])
    fremder_club = create(:club, game_operations_hash: [
      { 'home_game_operation' => true, 'game_operation_id' => go.id }
    ])
    login(create(:user, permissions: [
      { 'user_group_id' => 2, 'game_operation_id' => go.id },
      { 'user_group_id' => 4, 'club_id' => eigener_club.id }
    ]))

    # Gegenprobe: Die allgemeine Aktion liefert wegen der SBK-Rolle beide.
    get '/api/v2/user/clubs_and_teams'
    assert_response :success
    assert_includes JSON.parse(response.body).map { |c| c['id'] }, fremder_club.id

    get '/api/v2/vm/clubs_and_teams'
    assert_response :success
    assert_equal([eigener_club.id], JSON.parse(response.body).map { |c| c['id'] })
  end

  # Teammanager*innen sehen das Portal ebenfalls (menu_item_player_vm), haben
  # aber keine club_ids – ihre Vereine kommen ueber die eigenen Mannschaften.
  test 'vm_clubs_and_teams liefert TM den Verein der eigenen Mannschaft' do
    club = create(:club)
    team = create(:team, club: club, league: create(:league, :current_season))
    fremdes_team = create(:team, club: club, league: create(:league, :current_season))
    login(create(:user, :tm, team_id: team.id))

    get '/api/v2/vm/clubs_and_teams'

    assert_response :success
    entry = JSON.parse(response.body).find { |c| c['id'] == club.id }
    assert entry, 'Verein der eigenen Mannschaft muss enthalten sein'
    team_ids = entry['teams'].map { |t| t['id'] }
    assert_includes team_ids, team.id
    assert_not_includes team_ids, fremdes_team.id
  end

  test 'vm_clubs_and_teams ist ohne VM- und TM-Rolle gesperrt' do
    login(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

    get '/api/v2/vm/clubs_and_teams'

    assert_response :forbidden
  end

  test 'user_team_licenses ist für SBK eines fremden Spielbetriebs gesperrt' do
    go_other = create(:game_operation)
    team = create(:team, league: create(:league, :current_season))
    login(create(:user, :sbk_scoped, game_operation_id: go_other.id))

    get "/api/v2/user/team/#{team.id}/licenses"

    assert_response :forbidden
  end

  test 'user_team_licenses bleibt für den SBK des Spielbetriebs offen' do
    go = create(:game_operation)
    team = create(:team, league: create(:league, :current_season, game_operation: go))
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    get "/api/v2/user/team/#{team.id}/licenses"

    assert_response :success
  end

  test 'admin_upload_logo akzeptiert ein quadratisches PNG' do
    club = create(:club)
    login(create(:user, :admin))

    post "/api/v2/admin/clubs/#{club.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :success
    assert club.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt ein nicht-quadratisches Bild mit 422 ab' do
    club = create(:club)
    login(create(:user, :admin))

    post "/api/v2/admin/clubs/#{club.id}/upload_logo", params: { logo: png_upload(200, 100, 'wide') }

    assert_response :unprocessable_entity
    assert_match(/quadratisch/, JSON.parse(response.body)['message'])
    assert_not club.reload.logo.attached?
  end

  # --- Vereinsanlage ----------------------------------------------------------
  #
  # Das Bearbeiten-Formular hat seit 05/2026 kein Feld für den Spielbetrieb mehr
  # und schickte beim Anlegen `game_operation_id: 0`. Die Aktion lief damit in
  # GameOperation.find(0) und antwortete mit 404 „Nicht gefunden." – seitdem
  # konnte niemand mehr über die Oberfläche einen Verein anlegen.

  def create_club_params(game_operation_id:, **club_attrs)
    {
      id: 0,
      game_operation_id: game_operation_id,
      club: { name: 'Neuer Verein', short_name: 'NV', long_name: 'Neuer Verein e.V.',
              state: 'de-ni' }.merge(club_attrs)
    }
  end

  test 'admin_club_update legt einen Verein im eigenen Spielbetrieb an' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    post '/api/v2/admin/clubs', params: create_club_params(game_operation_id: go.id,
                                                           state_association_id: sa.id)

    assert_response :created
    club = Club.find(JSON.parse(response.body)['id'])
    assert_equal 'Neuer Verein', club.name
    assert_equal go.id, club.main_game_operation_id
  end

  # game_operation_id muss als Zahl im JSONB landen. Als String findet den Verein
  # keine der jsonb-@>-Abfragen, und er fehlt anschließend in der
  # Vereinsverwaltung – so entstanden in Produktion Vereine ohne Spielbetrieb.
  test 'admin_club_update speichert game_operation_id als Zahl' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    post '/api/v2/admin/clubs', params: create_club_params(game_operation_id: go.id.to_s)

    assert_response :created
    club = Club.find(JSON.parse(response.body)['id'])
    assert_equal go.id, club.game_operations_hash.first['game_operation_id'],
                 'game_operation_id muss als Integer gespeichert werden'
    assert_includes GameOperation.find(go.id).home_clubs.pluck(:id), club.id,
                    'Verein muss über home_clubs auffindbar sein'
  end

  test 'admin_club_update meldet einen fehlenden Spielbetrieb verstaendlich' do
    go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_no_difference('Club.count') do
      post '/api/v2/admin/clubs', params: create_club_params(game_operation_id: 0)
    end

    assert_response :unprocessable_entity
    assert_match 'Spielbetrieb', JSON.parse(response.body)['message']
  end

  test 'admin_club_update meldet einen unbekannten Spielbetrieb statt 404' do
    go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_no_difference('Club.count') do
      post '/api/v2/admin/clubs', params: create_club_params(game_operation_id: 999_999)
    end

    assert_response :unprocessable_entity
  end

  # --- Vereinsaenderung -------------------------------------------------------
  #
  # Der Zweig hatte keinen Test, obwohl dieser PR den Unterscheider zwischen
  # Anlage und Aenderung angefasst hat (params[:id].zero? -> to_i.zero?).

  test 'admin_club_update aendert einen bestehenden Verein und laesst den Spielbetrieb' do
    sa = create(:state_association)
    go = create(:game_operation, state_association_id: sa.id)
    club = create(:club, name: 'Alt', state_association_id: sa.id,
                         game_operations_hash: [{ 'game_operation_id' => go.id,
                                                  'home_game_operation' => true }])
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    assert_no_difference('Club.count') do
      post '/api/v2/admin/clubs', params: { id: club.id, game_operation_id: go.id,
                                            club: { name: 'Neu' } }
    end

    assert_response :success
    assert_equal 'Neu', club.reload.name
    assert_equal go.id, club.main_game_operation_id
  end

  # Das Formular schickt den ganzen Verein zurueck, also auch ein
  # game_operation_id, das es dort gar nicht zu bearbeiten gibt. Bei einem Verein
  # ohne Heimat-Eintrag ist das nil - und `params.key?` verstand dieses nil als
  # Aenderungswunsch. Betroffen waren ausgerechnet die Vereine ohne Spielbetrieb.
  test 'admin_club_update speichert einen Verein ohne Spielbetrieb, wenn keiner mitkommt' do
    club = create(:club, name: 'Alt', game_operations_hash: [])
    login(create(:user, :admin))

    post '/api/v2/admin/clubs', params: { id: club.id, game_operation_id: nil,
                                          club: { name: 'Neu' } }, as: :json

    assert_response :success
    assert_equal 'Neu', club.reload.name
    assert_nil club.main_game_operation_id, 'ohne Angabe bleibt der Verein ohne Spielbetrieb'
  end

  test 'admin_club_update wertet einen leeren Spielbetrieb als nicht mitgeschickt' do
    club = create(:club, name: 'Alt', game_operations_hash: [])
    login(create(:user, :admin))

    post '/api/v2/admin/clubs', params: { id: club.id, game_operation_id: '',
                                          club: { name: 'Neu' } }

    assert_response :success
    assert_equal 'Neu', club.reload.name
  end

  # Die Lockerung darf den Schutz nicht aufheben: eine ausdrueckliche 0 ist keine
  # fehlende Angabe, sondern eine Kennung, die es nicht gibt.
  test 'admin_club_update weist eine 0 auch bei einem Verein ohne Spielbetrieb ab' do
    club = create(:club, name: 'Alt', game_operations_hash: [])
    login(create(:user, :admin))

    post '/api/v2/admin/clubs', params: { id: club.id, game_operation_id: 0,
                                          club: { name: 'Neu' } }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'Alt', club.reload.name
  end

  # Ohne Pruefung am Ziel konnte ein Verband einen Verein in einen fremden
  # Spielbetrieb verschieben, der ihn nie aufgenommen hat - und verlor dabei
  # selbst den Zugriff.
  test 'admin_club_update verweigert das Verschieben in einen fremden Spielbetrieb' do
    eigen_go = create(:game_operation, state_association_id: create(:state_association).id)
    fremd_go = create(:game_operation, state_association_id: create(:state_association).id)
    club = create(:club, game_operations_hash: [{ 'game_operation_id' => eigen_go.id,
                                                  'home_game_operation' => true }])
    login(create(:user, :sbk_scoped, game_operation_id: eigen_go.id))

    post '/api/v2/admin/clubs', params: { id: club.id, game_operation_id: fremd_go.id,
                                          club: { name: 'Verschoben' } }

    assert_response :forbidden
    assert_equal eigen_go.id, club.reload.main_game_operation_id
  end

  # game_operation_id: 0 haette den Heimat-Eintrag auf einen Spielbetrieb gesetzt,
  # den es nicht gibt - der Verein waere aus jeder Vereinsliste verschwunden und
  # ueber die Oberflaeche nicht mehr auffindbar gewesen.
  test 'admin_club_update macht einen Verein nicht durch eine 0 unsichtbar' do
    go = create(:game_operation, state_association_id: create(:state_association).id)
    club = create(:club, game_operations_hash: [{ 'game_operation_id' => go.id,
                                                  'home_game_operation' => true }])
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    post '/api/v2/admin/clubs', params: { id: club.id, game_operation_id: 0,
                                          club: { name: 'Kaputt' } }

    assert_response :unprocessable_entity
    assert_equal go.id, club.reload.main_game_operation_id
    assert_includes GameOperation.find(go.id).home_clubs.pluck(:id), club.id
  end

  # Gegenprobe zum Wegfall des Gast-Eintrags: Altdaten mit einem solchen Eintrag
  # gibt es bis zum Bereinigungslauf noch, und das Speichern der Vereinsmaske
  # darf sie nicht wieder mitschleifen.
  test 'admin_club_update entfernt Gast-Eintraege beim Wechsel des Heimat-Spielbetriebs' do
    sa = create(:state_association)
    home_go = create(:game_operation, state_association_id: sa.id)
    other_go = create(:game_operation, state_association_id: sa.id)
    guest_go = create(:game_operation, state_association_id: create(:state_association).id)
    goh = [
      { 'game_operation_id' => home_go.id, 'home_game_operation' => true },
      { 'game_operation_id' => guest_go.id, 'home_game_operation' => false }
    ]
    club = create(:club, game_operations_hash: goh)
    # SBK beider Spielbetriebe, damit die Zielpruefung nicht greift.
    perms = [
      { 'user_group_id' => 2, 'game_operation_id' => home_go.id },
      { 'user_group_id' => 2, 'game_operation_id' => other_go.id }
    ]
    login(create(:user, permissions: perms))

    post '/api/v2/admin/clubs', params: { id: club.id, game_operation_id: other_go.id,
                                          club: { name: 'Umgezogen' } }

    assert_response :success
    club.reload
    assert_equal other_go.id, club.main_game_operation_id
    assert_equal [{ 'game_operation_id' => other_go.id, 'home_game_operation' => true }],
                 club.game_operations_hash
    refute_includes club.game_operations_hash.map { |h| h['game_operation_id'] }, guest_go.id
  end

  # Die Meldung soll den Grund nennen, nicht nur dass etwas fehlt.
  test 'admin_club_update unterscheidet fehlenden und unbekannten Spielbetrieb' do
    go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: go.id))

    post '/api/v2/admin/clubs', params: create_club_params(game_operation_id: 999_999)
    assert_match 'existiert nicht', JSON.parse(response.body)['message']

    post '/api/v2/admin/clubs', params: create_club_params(game_operation_id: 0)
    assert_match 'auswählen', JSON.parse(response.body)['message']
  end

  test 'admin_club_update verweigert die Anlage im fremden Spielbetrieb' do
    eigen_go = create(:game_operation, state_association_id: create(:state_association).id)
    fremd_go = create(:game_operation, state_association_id: create(:state_association).id)
    login(create(:user, :sbk_scoped, game_operation_id: eigen_go.id))

    assert_no_difference('Club.count') do
      post '/api/v2/admin/clubs', params: create_club_params(game_operation_id: fremd_go.id)
    end

    assert_response :forbidden
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
end
