require 'test_helper'

# Aufstellen mit einem gestellten, aber noch nicht entschiedenen Lizenzantrag.
#
# Standard bleibt: nur eine erteilte Lizenz zaehlt. Setzt der Landesverband des
# Spielbetriebs `requested_license_playable`, zaehlt der Status „beantragt"
# ebenfalls -- fuer die Warnung beim Aufstellen und fuer das Feld, an dem der
# Kader-Dialog im Frontend seine Liste filtert.
class GamesRequestedLicensePlayableTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association: @sa)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @home_team = create(:team, league: @league, club: @club)
    @guest_team = create(:team, league: @league, club: create(:club))
    game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date: '2026-01-10')
    @game = Game.create!(game_day: game_day, home_team: @home_team, guest_team: @guest_team,
                         forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] })

    @requested = create(:player,
                        clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                        with_licenses: [{ team: @home_team, status: License::REQUESTED }])
    @denied = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                     with_licenses: [{ team: @home_team, status: License::DENIED }])

    login(create(:user, :admin))
  end

  test 'ohne den Schalter bleibt ein beantragter Antrag eine Warnung' do
    assert_not @game.requested_license_playable?

    warnung = aufstellen(@requested, 7)

    assert_match(/nicht erteilt/, warnung)
    assert_match(/beantragt/, warnung)
  end

  test 'mit dem Schalter zaehlt der gestellte Antrag wie eine erteilte Lizenz' do
    @sa.update!(requested_license_playable: true)

    assert_nil aufstellen(@requested, 7)
  end

  test 'der Schalter erlaubt nur den offenen Antrag, nicht den abgelehnten' do
    @sa.update!(requested_license_playable: true)

    warnung = aufstellen(@denied, 8)

    assert_match(/nicht erteilt/, warnung)
    assert_match(/abgelehnt/, warnung)
  end

  # Massgeblich ist der Landesverband des Spielbetriebs der Liga, nicht der des
  # Vereins. Eine Mannschaft, deren Verein in einem grosszuegigen Landesverband
  # sitzt, spielt in einer fremden Liga trotzdem nach deren Regel.
  test 'entschieden wird am Landesverband der Liga, nicht an dem des Vereins' do
    vereins_lv = create(:state_association, requested_license_playable: true)
    @club.update!(state_association_id: vereins_lv.id)

    warnung = aufstellen(@requested, 7)

    assert_match(/nicht erteilt/, warnung)
  end

  test 'ein Kind-LV erbt die Regel seines Verbunds' do
    verbund = create(:state_association, requested_license_playable: true)
    @sa.update!(parent: verbund)

    assert Game.find(@game.id).requested_license_playable?
    assert_nil aufstellen(@requested, 7)
  end

  test 'der Spielabruf nennt die Regel, damit der Kader-Dialog danach filtern kann' do
    assert_not @game.full_hash[:requested_license_playable]

    @sa.update!(requested_license_playable: true)

    assert Game.find(@game.id).full_hash[:requested_license_playable]
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def aufstellen(player, trikot_number)
    post "/api/v2/user/games/#{@game.id}/lineup/home/add_player",
         params: { player_id: player.id, trikot_number: trikot_number }

    assert_response :success
    JSON.parse(response.body)['warning']
  end
end
