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

  def treffer_fuer(player)
    get '/api/v2/admin/players/search', params: { q: 'Kennzeichen' }
    assert_response :success
    JSON.parse(response.body).find { |p| p['id'] == player.id }
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
end
