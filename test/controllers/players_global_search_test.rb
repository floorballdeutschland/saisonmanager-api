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
end
