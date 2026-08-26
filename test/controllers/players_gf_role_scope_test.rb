require 'test_helper'

# Das Spielerprofil (admin/players/:id) weist je Lizenz aus, ob dieses Konto die
# Erst-/Zweitlizenz-Zuordnung setzen darf (`gf_role_editable`). Zustaendig ist
# der Spielbetrieb der Liga, an der die Lizenz haengt -- dieselbe Regel, die
# `set_gf_license_role` beim Schreiben anwendet.
#
# Eigene Datei und nicht in players_controller_test.rb: Die Sammeldatei ist an
# der Laengengrenze (Metrics/ClassLength), und diese Pruefungen haengen
# zusammen -- Anzeige und Schreibweg werden hier gegeneinander gehalten.
class PlayersGfRoleScopeTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @game_operation = create(:game_operation)
    @club = create(:club, game_operation: @game_operation)
    @league = create(:league, :current_season, game_operation: @game_operation)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def license_for(player, team)
    player.reload.licenses.find { |l| l['team_id'].to_i == team.id }
  end

  # Das Profil zeigt alle Lizenzen der Person, auch die aus fremden
  # Spielbetrieben. Ob die Erst-/Zweitlizenz-Zuordnung dort angeboten werden
  # darf, entscheidet der Spielbetrieb der Liga -- dieselbe Regel, die
  # set_gf_license_role beim Schreiben anwendet. Ohne diese Angabe in der
  # Antwort bot die Maske die Knoepfe auf jeder GF-Erwachsenenlizenz an, und der
  # Klick auf eine fremde endete in einer 403.
  test 'admin_player weist je Lizenz aus, ob die Erst-/Zweitlizenz-Zuordnung im eigenen Spielbetrieb liegt' do
    home_club = create(:club, game_operation: @game_operation)
    own_league = create(:league, :current_season, game_operation: @game_operation,
                                                  field_size: 'GF', league_class_id: 'rl')
    own_team = create(:team, league: own_league, club: home_club)

    foreign_league = create(:league, :current_season, game_operation: create(:game_operation),
                                                     field_size: 'GF', league_class_id: '2fbl')
    foreign_team = create(:team, league: foreign_league, club: home_club)

    player = create(:player,
                    clubs: [{ 'club_id' => home_club.id, 'home_club' => true,
                              'created_at' => 1.day.ago.iso8601 }],
                    with_licenses: [
                      { team: own_team, status: License::REQUESTED },
                      { team: foreign_team, status: License::REQUESTED }
                    ])

    # Der zweite Spielbetrieb ist Voraussetzung des Falls, nicht Beiwerk: Deckte
    # die Rolle ALLE vorhandenen Spielbetriebe ab, kochte permission_hash sie auf
    # den globalen Scope [0] ein -- dann waeren beide Flags true und der Test
    # pruefte nichts. Geprueft wird der Scope selbst und nicht die Zahl der
    # Spielbetriebe, denn die haengt an Factory-Interna.
    sbk = create(:user, :sbk_scoped, game_operation_id: @game_operation.id)
    assert_equal [@game_operation.id], sbk.permission_hash[:sbk],
                 'Rolle darf nicht in den globalen Scope kippen'

    login_as(sbk)
    get "/api/v2/admin/players/#{player.id}.json", params: { all_licenses: 'true' }
    assert_response :success

    flags = gf_role_flags(response)
    assert_equal true,  flags[own_team.id],     'eigene Liga: Zuordnung erlaubt'
    assert_equal false, flags[foreign_team.id], 'fremder Spielbetrieb: keine Zuordnung'

    # Die Zusage des Feldes an den Schreibweg binden: Ohne diese Probe koennten
    # Anzeige und Entscheidung auseinanderlaufen, ohne dass ein Test es merkt --
    # und genau das war der gemeldete Fehler (Knopf sichtbar, Aktion abgewiesen,
    # Rauswurf aus der Maske).
    foreign_license_id = license_for(player, foreign_team)['id']
    post "/api/v2/admin/players/#{player.id}/set_gf_license_role",
         params: { license_id: foreign_license_id, gf_role: 'erstlizenz' }, as: :json
    assert_response :forbidden, 'was die Anzeige verneint, muss der Schreibweg abweisen'

    login_as(create(:user, :admin))
    get "/api/v2/admin/players/#{player.id}.json", params: { all_licenses: 'true' }
    assert_response :success

    flags = gf_role_flags(response)
    assert_equal [true, true], [flags[own_team.id], flags[foreign_team.id]],
                 'Admin ordnet in jedem Spielbetrieb zu'
  end

  # Eine Lizenz ohne aufloesbare Liga ist fuer NIEMANDEN zuordenbar, auch nicht
  # fuer Admin: Der Schreibweg scheitert dort an `unless league&.gf_adult?` mit
  # 422. Meldete das Feld hier true, verspraeche es etwas, das kein Konto
  # einloesen kann -- und `admin ||` kuerzte genau daran vorbei.
  test 'admin_player meldet eine Lizenz ohne aufloesbare Liga fuer niemanden als zuordenbar' do
    # Heimatverein im eigenen Spielbetrieb, sonst scheitert schon der Zugriff auf
    # das Profil und der Test pruefte die Absage statt des Feldes:
    # sbk_can_access_player? liest den Heimatverein, und der @club aus dem Setup
    # hat gar keinen Landesverband, ist also fuer niemanden zustaendig.
    home_club = create(:club, game_operation: @game_operation)
    orphan_team = create(:team, league: @league, club: home_club)
    player = create(:player,
                    clubs: [{ 'club_id' => home_club.id, 'home_club' => true,
                              'created_at' => 1.day.ago.iso8601 }],
                    with_licenses: [{ team: orphan_team, status: License::REQUESTED }])
    orphan_team.update_column(:league_id, nil)

    [create(:user, :admin), create(:user, :sbk_global),
     create(:user, :sbk_scoped, game_operation_id: @game_operation.id)].each do |user|
      login_as(user)
      get "/api/v2/admin/players/#{player.id}.json", params: { all_licenses: 'true' }
      assert_response :success
      assert_equal false, gf_role_flags(response)[orphan_team.id],
                   "#{user.permissions.inspect}: ohne Liga keine Zuordnung"
    end
  end

  def gf_role_flags(response)
    JSON.parse(response.body)['licenses'].to_h { |l| [l['team_id'].to_i, l['gf_role_editable']] }
  end
end
