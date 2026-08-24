require 'test_helper'

# Wer eine Vereinszugehörigkeit angelegt oder beendet hat, stand als Konto-ID in
# den Einträgen (created_by, valid_set_by) und reiste auch schon im JSON mit,
# blieb damit aber unlesbar. Ein Transfer oder eine Freigabe war nachträglich
# nicht nachvollziehbar. Aufgelöst wird der Name nur für Admin und die
# zuständige SBK: can_manage_player? lässt auch Vereins- und Teammanager an
# diese Ansicht.
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
    assert_equal handelnd.full_with_username, entry['created_by_name']
    assert_equal beendend.full_with_username, entry['valid_set_by_name']
  end

  test 'SBK sieht die handelnden Konten ebenfalls' do
    handelnd = create(:user, :admin)
    player = player_with('created_by' => handelnd.id)

    login_as(create(:user, :sbk_global))
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success
    assert_equal handelnd.full_with_username, first_club_entry['created_by_name']
  end

  # Der Vereinsmanager darf das Profil lesen, aber das handelnde Konto eines
  # Verbandes ist keine Auskunft, die dieses Profil ihm schuldet.
  test 'Vereinsmanager sieht keine Namen, die IDs bleiben unverändert' do
    handelnd = create(:user, :admin)
    player = player_with('created_by' => handelnd.id)

    login_as(create(:user, :vm, club_id: @club.id))
    get "/api/v2/admin/players/#{player.id}.json"
    assert_response :success

    entry = first_club_entry
    assert_nil entry['created_by_name']
    assert_equal handelnd.id, entry['created_by'], 'die ID war schon vorher enthalten'
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
