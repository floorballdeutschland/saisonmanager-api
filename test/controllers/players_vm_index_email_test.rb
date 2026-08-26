require 'test_helper'

# „Meine Spieler*innen" ist die Maske, in der ein Verein die E-Mail-Adressen
# seiner Spielerinnen und Spieler pflegt (PlayersController#update_email
# schreibt direkt daneben). Die Liste selbst nannte die Adresse bisher nicht;
# wer wissen wollte, bei wem sie fehlt, musste jedes Profil einzeln oeffnen.
#
# Ausgegeben wird sie nur an das Recht, das auch das Profil oeffnet
# (can_manage_player?). Fuer VM und TM deckt sich das mit der Liste, fuer die
# SBK nicht -- siehe den Test unten.
class PlayersVmIndexEmailTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation)
    @league = create(:league, :current_season, game_operation: @go)
    @club = create(:club, game_operation: @go)
    @team = create(:team, league: @league, club: @club)
    @mit_adresse = create(:player, email: 'spielerin@example.org',
                                   clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    @ohne_adresse = create(:player, email: nil,
                                    clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
  end

  test 'die Vereinsliste nennt die E-Mail-Adresse je Person' do
    login(create(:user, :vm, club_id: @club.id))

    assert_equal 'spielerin@example.org', eintrag(@mit_adresse)['email']

    # Ausdruecklich auf den Schluessel pruefen: Ein fehlendes Feld liest sich
    # als nil und saehe genauso aus wie eine ungepflegte Adresse.
    ohne = eintrag(@ohne_adresse)
    assert ohne.key?('email'), 'die Liste muss das Feld auch ohne Adresse nennen'
    assert_nil ohne['email']
  end

  # Der Teammanager sieht denselben Bestand und oeffnet dieselben Profile. Die
  # Praemisse wird mitgeprueft und nicht bloss behauptet: Sie ist der Grund,
  # warum die Spalte fuer ihn nichts offenlegt.
  test 'der Teammanager sieht die Adresse und darf dasselbe Profil oeffnen' do
    login(create(:user, :tm, team_id: @team.id))

    assert_equal 'spielerin@example.org', eintrag(@mit_adresse)['email']

    get "/api/v2/admin/players/#{@mit_adresse.id}"
    assert_response :success
    assert_equal 'spielerin@example.org', JSON.parse(response.body)['email']
  end

  # Die Liste haengt am Verein (Club#players nimmt jede gueltige
  # Zugehoerigkeit), sbk_can_access_player? dagegen am Heimatverein der Person.
  # Eine Zweitmitgliedschaft im eigenen Verein bei Heimatverein in einem fremden
  # Verband steht deshalb in der Liste, ihr Profil antwortet aber mit 403. Ohne
  # die Bindung an can_manage_player? waere die Spalte fuer genau diese Zeilen
  # der einzige Weg zur Adresse gewesen.
  test 'die SBK bekommt keine Adresse zu einer Person aus einem fremden Verband' do
    fremder_verein = create(:club, game_operation: create(:game_operation))
    gast = create(:player, email: 'gast@example.org',
                           clubs: [{ 'club_id' => fremder_verein.id, 'home_club' => true },
                                   { 'club_id' => @club.id, 'home_club' => false }])

    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    zeile = eintrag(gast)
    assert zeile, 'die Person steht weiterhin in der Liste'
    assert_nil zeile['email'], 'ohne Profilrecht darf die Adresse nicht mitkommen'
    assert_not_includes response.body, 'gast@example.org'

    # Die Praemisse: Genau dieses Profil bleibt der SBK verschlossen.
    get "/api/v2/admin/players/#{gast.id}"
    assert_response :forbidden
  end

  # Gegenprobe zum Fall darueber: Fuer die eigenen Personen des Spielbetriebs
  # bekommt die SBK die Adresse wie bisher.
  test 'die SBK bekommt die Adresse zu einer Person des eigenen Spielbetriebs' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    assert_equal 'spielerin@example.org', eintrag(@mit_adresse)['email']
  end

  private

  def eintrag(player)
    get "/api/v2/admin/vm/players?club_id=#{@club.id}"
    assert_response :success
    JSON.parse(response.body).find { |p| p['id'] == player.id }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
