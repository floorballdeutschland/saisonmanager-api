require 'test_helper'

# „Meine Spieler*innen" ist die Maske, in der ein Verein die E-Mail-Adressen
# seiner Spielerinnen und Spieler pflegt (PlayersController#update_email
# schreibt direkt daneben). Die Liste selbst nannte die Adresse bisher nicht;
# wer wissen wollte, bei wem sie fehlt, musste jedes Profil einzeln oeffnen.
class PlayersVmIndexEmailTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation)
    @league = create(:league, :current_season, game_operation: @go)
    @club = create(:club)
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

  # Der Teammanager sieht denselben Bestand und oeffnet dieselben Profile
  # (`can_manage_player?` laesst ihn an full_hash, das die Adresse nennt). Die
  # Spalte legt fuer ihn also nichts offen, was er nicht ohnehin sieht.
  test 'der Teammanager sieht die Adresse in derselben Liste' do
    login(create(:user, :tm, team_id: @team.id))

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
