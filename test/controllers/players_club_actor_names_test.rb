require 'test_helper'

# Wer eine Vereinszugehörigkeit angelegt oder beendet hat, stand als Konto-ID in
# den Einträgen (created_by, valid_set_by) und reiste auch schon im JSON mit,
# blieb damit aber unlesbar. Ein Transfer oder eine Freigabe war nachträglich
# nicht nachvollziehbar.
#
# Aufgelöst wird für jeden, der das Profil öffnen darf. Eine engere Fassung wäre
# in derselben Antwort schon widerlegt: Die Lizenzhistorie löst created_by_name
# ungeprüft auf und die Profilmaske zeigt es an, Vereins- und Teammanager sehen
# dort seit langem Verbandskonten. Ausgegeben wird der Name ohne Benutzernamen,
# der ist in diesem Projekt die halbe Anmeldung.
class PlayersClubActorNamesTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @game_operation = create(:game_operation)
    @club = create(:club)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def player_with(entry)
    create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }.merge(entry)])
  end

  def first_club_entry
    JSON.parse(response.body)['clubs'].first
  end

  test 'Admin sieht die handelnden Konten beider Spalten' do
    admin = create(:user, :admin)
    handelnd = create(:user, :admin)
    beendend = create(:user, :admin)
    player = player_with('created_by' => handelnd.id, 'valid_set_by' => beendend.id,
                         'valid_until' => '2026-06-30')

    login_as(admin)
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success

    entry = first_club_entry
    assert_equal handelnd.fullname, entry['created_by_name']
    assert_equal beendend.fullname, entry['valid_set_by_name']
  end

  test 'SBK sieht die handelnden Konten ebenfalls' do
    handelnd = create(:user, :admin)
    player = player_with('created_by' => handelnd.id)

    login_as(create(:user, :sbk_global))
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success
    assert_equal handelnd.fullname, first_club_entry['created_by_name']
  end

  # Der Vereinsmanager sieht sie ebenfalls: Die Lizenzhistorie derselben Maske
  # zeigt ihm seit langem, welches Verbandskonto eine Lizenz genehmigt hat, eine
  # Ausnahme allein fuer die Vereinseintraege waere nicht vermittelbar.
  test 'Vereinsmanager sieht die handelnden Konten ebenfalls' do
    handelnd = create(:user, :admin)
    player = player_with('created_by' => handelnd.id)

    login_as(create(:user, :vm, club_id: @club.id))
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success

    entry = first_club_entry
    assert_equal handelnd.fullname, entry['created_by_name']
    assert_equal handelnd.id, entry['created_by'], 'die ID war schon vorher enthalten'
  end

  # Der Benutzername ist in diesem Projekt die halbe Anmeldung; fuer die Frage
  # "wer war das" genuegen Name und Konto-ID.
  test 'Konto-Name enthaelt den Benutzernamen nicht' do
    handelnd = create(:user, :admin)
    player = player_with('created_by' => handelnd.id)

    login_as(create(:user, :admin))
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success

    name = first_club_entry['created_by_name']
    assert_equal handelnd.fullname, name
    assert_not_includes name.to_s, handelnd.user_name
  end

  # Ein zwischenzeitlich gelöschtes Konto darf die Antwort nicht sprengen; die
  # ID bleibt die belastbare Angabe.
  test 'unauffindbares Konto liefert die ID ohne Namen' do
    player = player_with('created_by' => 999_999)

    login_as(create(:user, :admin))
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success

    entry = first_club_entry
    assert_equal 999_999, entry['created_by']
    assert_nil entry['created_by_name']
  end

  # Eine Zugehörigkeit aus dem Altbestand trägt keine Konto-Spalten; die
  # Auflösung darf daran nicht scheitern.
  test 'Zugehörigkeit ohne Konto-Spalten bleibt unangetastet' do
    player = player_with({})

    login_as(create(:user, :admin))
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success

    entry = first_club_entry
    assert_equal @club.id, entry['club_id']
    assert_nil entry['created_by_name']
  end
end
