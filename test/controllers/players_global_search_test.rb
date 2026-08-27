require 'test_helper'

# global_search (GET admin/players/search) — die Spielersuche der SBK unter
# /verwaltung/spieler/suche.
#
# Der Filter dieser Suche entscheidet, ob ein Profil ueberhaupt noch erreichbar ist.
# Bis api#472 lief er ueber `Player.active` und schloss damit jedes deaktivierte
# Profil aus. Zusammen mit der alten Deaktivierung, die die Vereinszugehoerigkeit
# schloss, war ein Profil nach dem Grund "Vereinsaustritt" fuer niemanden mehr zu
# finden und ohne Heimatverein auch nicht mehr transferierbar.
class PlayersGlobalSearchTest < ActionDispatch::IntegrationTest
  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  # global_search (Spielersuche /verwaltung/spieler/suche): zusammengefuehrte
  # Profile sind durch ihren Master ersetzt und duerfen nicht erscheinen (api#92).
  test 'global_search findet keine zusammengefuehrten Dubletten' do
    admin = create(:user, :admin)
    master = create(:player, first_name: 'Master', last_name: 'Suchbar')
    dublette = create(:player, first_name: 'Dublette', last_name: 'Suchbar')
    dublette.merge_into!(master, admin.id)

    login_as(admin)
    get '/api/v2/admin/players/search', params: { q: 'Suchbar' }

    assert_response :success
    ids = JSON.parse(response.body).map { |p| p['id'] }
    assert_includes ids, master.id
    assert_not_includes ids, dublette.id
  end

  # Der Regressionsfall von api#472: Ein Verein nimmt ein Profil mit dem Grund
  # "Vereinsaustritt" aus seiner Liste, und danach findet die SBK die Person nicht
  # mehr — der aufnehmende Verein kommt an sie nicht heran. Die Deaktivierung ist
  # eine Kennzeichnung der Vereinsansicht und darf die Suche nicht beschneiden.
  test 'global_search findet deaktivierte Spieler und kennzeichnet sie' do
    admin = create(:user, :admin)
    ausgetreten = create(:player, first_name: 'Ausgetreten', last_name: 'Suchbar')
    ausgetreten.deactivate!(admin.id, reason: 'Vereinsaustritt')

    login_as(admin)
    get '/api/v2/admin/players/search', params: { q: 'Suchbar' }

    assert_response :success
    treffer = JSON.parse(response.body).find { |p| p['id'] == ausgetreten.id }
    assert_not_nil treffer, 'deaktiviertes Profil muss auffindbar bleiben'
    assert_not_nil treffer['deactivated_at'], 'der Treffer muss die Kennzeichnung mitgeben'
  end

  # Ab hier: die Kennzeichnung, ob ein Treffer auch zu oeffnen ist.
  #
  # Die Suche geht ueber den gesamten Bestand, `admin_player` nicht: Fuer eine auf
  # einen Spielbetrieb begrenzte SBK entscheidet der Heimatverein
  # (sbk_can_access_player?). Jeder Treffer aus einem anderen Landesverband war
  # damit ein Link, der mit 403 endet — und das Frontend warf auf die Startseite,
  # samt der gerade eingegebenen Suche. Die Absage gehoert in die Trefferliste,
  # bevor jemand klickt.
  def spieler_im(club)
    create(:player, last_name: 'Kennzeichen', first_name: 'Test',
                    clubs: [{ 'club_id' => club.id, 'home_club' => true }])
  end

  # assert_not_nil vor der Rueckgabe: Faellt die Kennzeichnung aus, soll der Test
  # das sagen und nicht mit einem NoMethodError auf nil abbrechen.
  def treffer_fuer(player)
    get '/api/v2/admin/players/search', params: { q: 'Kennzeichen' }
    assert_response :success
    treffer = JSON.parse(response.body).find { |p| p['id'] == player.id }
    assert_not_nil treffer, "Spieler ##{player.id} fehlt in der Trefferliste"
    treffer
  end

  test 'begrenzte SBK sieht den eigenen Treffer als oeffenbar' do
    create(:setting)
    go = create(:game_operation)
    eigener = spieler_im(create(:club, game_operation: go))

    login_as(create(:user, :sbk_scoped, game_operation_id: go.id))

    treffer = treffer_fuer(eigener)
    assert_equal true, treffer['manageable']
    assert_nil treffer['responsible'], 'ein oeffenbarer Treffer braucht keinen Verweis'
  end

  test 'begrenzte SBK sieht den fremden Treffer als gesperrt und erfaehrt den zustaendigen Verband' do
    create(:setting)
    eigener_go = create(:game_operation)
    fremder_go = create(:game_operation, name: 'SBK Anderswo')
    fremder = spieler_im(create(:club, game_operation: fremder_go))

    login_as(create(:user, :sbk_scoped, game_operation_id: eigener_go.id))

    treffer = treffer_fuer(fremder)
    assert_not_nil treffer, 'der Treffer bleibt in der Liste, nur eben ohne Zugriff'
    assert_equal false, treffer['manageable']
    assert_equal 'SBK Anderswo', treffer['responsible']
  end

  # Gegenprobe zur Rechteregel selbst: Was die Suche als gesperrt kennzeichnet,
  # weist `admin_player` auch wirklich ab. Ohne diese Klammer koennte die
  # Kennzeichnung strenger oder lascher werden als die Maske dahinter, ohne dass
  # ein Test es merkt.
  test 'was die Suche als gesperrt kennzeichnet, weist das Profil ab' do
    create(:setting)
    fremder = spieler_im(create(:club, game_operation: create(:game_operation)))

    login_as(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

    assert_equal false, treffer_fuer(fremder)['manageable']

    get "/api/v2/admin/players/#{fremder.id}.json"
    assert_response :forbidden
  end

  # Ohne gueltige Heimat-Zugehoerigkeit ist niemand zustaendig (api#389). Der
  # Hinweis nennt dann keinen Verband, statt einen zu erfinden.
  test 'ohne Heimatverein bleibt der zustaendige Verband offen' do
    create(:setting)
    heimatlos = create(:player, last_name: 'Kennzeichen', first_name: 'Test', clubs: [])

    login_as(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

    treffer = treffer_fuer(heimatlos)
    assert_equal false, treffer['manageable']
    assert_nil treffer['responsible']
  end

  test 'Admin darf jeden Treffer oeffnen' do
    create(:setting)
    fremder = spieler_im(create(:club, game_operation: create(:game_operation)))

    login_as(create(:user, :admin))

    assert_equal true, treffer_fuer(fremder)['manageable']
  end

  # Die bundesweite SBK (game_operation_id 0) ist ein eigener Zweig in
  # `sbk_can_access_player?` und nicht dasselbe wie Admin. Sie ist zugleich die
  # Rolle, auf die der Hinweistext bei einem Profil ohne Heimat verweist.
  test 'bundesweite SBK darf jeden Treffer oeffnen' do
    create(:setting)
    fremder = spieler_im(create(:club, game_operation: create(:game_operation)))
    heimatlos = create(:player, last_name: 'Kennzeichen', first_name: 'Ohne', clubs: [])

    login_as(create(:user, :sbk_global))

    assert_equal true, treffer_fuer(fremder)['manageable']
    assert_equal true, treffer_fuer(heimatlos)['manageable']
  end

  # Die Kennzeichnung haengt an `can_manage_player?` und damit an ALLEN Rollen des
  # Kontos, nicht nur an der SBK-Rolle. Wer SBK des einen und Vereinsmanager im
  # anderen Verband ist, muss die eigenen Vereinsmitglieder oeffnen koennen — sonst
  # kaeme genau der Fehler zurueck, den api#561 einen Tag zuvor behoben hat.
  #
  # Eine Verkuerzung auf `sbk_can_access_player?` waere die naheliegende
  # Optimierung (sie spart den doppelten Heimatverein-Zugriff) und faellt hier auf.
  test 'Doppelrolle SBK und Vereinsmanager oeffnet den eigenen Vereinsspieler' do
    create(:setting)
    eigener_go = create(:game_operation)
    fremder_verein = create(:club, game_operation: create(:game_operation))
    eigenes_mitglied = spieler_im(fremder_verein)

    user = create(:user, permissions: [
      { 'user_group_id' => 2, 'game_operation_id' => eigener_go.id },
      { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => fremder_verein.id }
    ])
    login_as(user)

    assert_equal true, treffer_fuer(eigenes_mitglied)['manageable'],
                 'die Vereinsmanager-Rolle muss den eigenen Spieler oeffnen'
  end

  # Der Sinn der Kennzeichnung ist die gemischte Liste: In einer Antwort stehen
  # eigene und fremde Treffer nebeneinander. Ein je Anfrage gecachtes Urteil oder
  # eine aus der Schleife gezogene Pruefung faellt genau hier auf, nicht an den
  # Einzelfaellen darueber.
  test 'eine Antwort kennzeichnet eigene und fremde Treffer verschieden' do
    create(:setting)
    eigener_go = create(:game_operation)
    fremder_go = create(:game_operation, name: 'SBK Anderswo')
    eigener = spieler_im(create(:club, game_operation: eigener_go))
    fremder = spieler_im(create(:club, game_operation: fremder_go))

    login_as(create(:user, :sbk_scoped, game_operation_id: eigener_go.id))

    get '/api/v2/admin/players/search', params: { q: 'Kennzeichen' }
    assert_response :success
    treffer = JSON.parse(response.body).index_by { |p| p['id'] }

    assert_equal true, treffer[eigener.id]['manageable']
    assert_equal false, treffer[fremder.id]['manageable']
    assert_equal 'SBK Anderswo', treffer[fremder.id]['responsible']
  end

  # Zweite Ursache fuer ein leeres `responsible`: Die Person hat einen gueltigen
  # Heimatverein, aber fuer den ist kein Spielbetrieb zustaendig
  # (`Club#main_game_operation_id` ist dort nil). Der Hinweis darf deshalb keine
  # Ursache behaupten — der Fall betrifft die Vereine ohne Landesverband, nicht
  # Personen ohne Mitgliedschaft.
  test 'Verein ohne zustaendigen Spielbetrieb laesst den Verband ebenfalls offen' do
    create(:setting)
    ohne_verband = spieler_im(create(:club, state_association: nil))

    login_as(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

    treffer = treffer_fuer(ohne_verband)
    assert_equal false, treffer['manageable']
    assert_nil treffer['responsible']
  end

  # Die Zustaendigkeit laeuft ueber die WURZEL der Verbandskette
  # (`StateAssociation.root_id`), nicht ueber den Landesverband des Vereins. Fuer
  # einen Verein in einem untergeordneten Landesverband ist also die SBK des
  # Verbunds zustaendig, und genau die muss der Hinweis nennen.
  test 'im Spielverbund zaehlt der Verband der Wurzel' do
    create(:setting)
    verbund_go = create(:game_operation, name: 'SBK Verbund')
    kind_lv = create(:state_association, parent_id: verbund_go.state_association.id)
    im_kind_lv = spieler_im(create(:club, state_association: kind_lv))

    login_as(create(:user, :sbk_scoped, game_operation_id: verbund_go.id))
    assert_equal true, treffer_fuer(im_kind_lv)['manageable']

    login_as(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))
    treffer = treffer_fuer(im_kind_lv)
    assert_equal false, treffer['manageable']
    assert_equal 'SBK Verbund', treffer['responsible']
  end

  # Eine Vereins-Freigabe (StateAssociationRelease) gibt Einsicht in die Vereins-
  # und Mannschaftsansichten, aber keine Zustaendigkeit fuer die Person: Das
  # entscheidet ausschliesslich der Heimat-Spielbetrieb (api#389). Die
  # Kennzeichnung muss dieselbe Grenze ziehen wie die Maske dahinter, sonst
  # verlinkt die Liste wieder ins 403.
  test 'eine Vereins-Freigabe macht den Treffer nicht oeffenbar' do
    create(:setting)
    empfaenger_go = create(:game_operation)
    fremder_go = create(:game_operation, name: 'SBK Anderswo')
    fremder_verein = create(:club, game_operation: fremder_go)
    fremder = spieler_im(fremder_verein)
    StateAssociationRelease.create!(grantor_state_association_id: fremder_verein.state_association_id,
                                    recipient_game_operation_id: empfaenger_go.id,
                                    season_id: Setting.current_season_id)

    login_as(create(:user, :sbk_scoped, game_operation_id: empfaenger_go.id))

    treffer = treffer_fuer(fremder)
    assert_equal false, treffer['manageable']
    assert_equal 'SBK Anderswo', treffer['responsible']

    get "/api/v2/admin/players/#{fremder.id}.json"
    assert_response :forbidden
  end
end
