require 'test_helper'

# Neuer Lizenzantrag nach Transfer und Freigabe zurueck.
#
# Fall aus Prod (Spieler 1340): Lizenz fuer Verein B erteilt, dann Transfer von
# B nach A (die Lizenz wird „ungültig wg. Transfer"), dann Freigabe von A an B.
# Die Mitgliedschaft bei B war damit wieder da, beantragen konnte B trotzdem
# nicht: Die alte Lizenz hielt den Spieler aus der Auswahl `other_players`
# heraus, und einen Knopf „erneut beantragen" gibt es fuer diesen Status nicht.
#
# Die neue Lizenz wird angehaengt, die alte steht also vorn im Array. Jeder
# Leser, der die erste Lizenz der Mannschaft nahm, sah danach weiter die alte.
class PlayersLicenseAfterTransferTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @home_club = create(:club)
    @club = create(:club)
    @league = create(:league, :current_season)
    @team = create(:team, league: @league, club: @club)
    @vm = create(:user, :vm, club_id: @club.id)
    @admin = create(:user, :admin)
    @player = create(:player, clubs: [
      { 'club_id' => @home_club.id, 'home_club' => true, 'created_at' => 2.days.ago.iso8601 },
      { 'club_id' => @club.id, 'home_club' => false, 'created_at' => 2.days.ago.iso8601,
        'valid_until' => 1.year.from_now.iso8601 }
    ])
    @player.update!(licenses: [transfer_license])
  end

  def transfer_license
    {
      'id' => 'alt', 'team_id' => @team.id,
      'season_id' => @league.season_id, 'league_class_id' => @league.league_class_id,
      'history' => [
        { 'license_status_id' => License::REQUESTED, 'created_at' => 5.days.ago.iso8601 },
        { 'license_status_id' => License::APPROVED, 'created_at' => 4.days.ago.iso8601 },
        { 'license_status_id' => License::TRANSFER, 'created_at' => 2.days.ago.iso8601, 'reason' => 'Transfer' }
      ]
    }
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def team_licenses
    get "/api/v2/user/team/#{@team.id}/licenses"
    assert_response :success
    JSON.parse(response.body)
  end

  def request_new_license
    login_as(@vm)
    post "/api/v2/user/players/#{@player.id}/request_license", params: { team_id: @team.id }, as: :json
    assert_response :success
    @player.reload.licenses.find { |l| l['id'] != 'alt' }
  end

  def approve(license)
    login_as(@admin)
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license['id'], license_status_id: License::APPROVED }, as: :json
    assert_response :success
  end

  def build_game
    game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club, number: 1, date: Date.current)
    Game.create!(game_day: game_day, home_team: @team, guest_team: create(:team, league: @league),
                 forfait: 0, overtime: false, legacy: false,
                 events: [], players: { 'home' => [], 'guest' => [] })
  end

  test 'Spieler mit Transferlizenz steht in der Auswahl fuer einen neuen Antrag' do
    login_as(@vm)
    body = team_licenses

    assert(body['other_players'].any? { |p| p['id'] == @player.id },
           'der zurueckgekehrte Spieler muss neu beantragt werden koennen')
    assert_not(body['current_requests'].any? { |p| p['id'] == @player.id })
  end

  test 'neuer Antrag geht durch und ersetzt in der Maske die Transferlizenz' do
    request_new_license
    assert_equal 2, @player.licenses.size

    body = team_licenses
    item = body['current_requests'].find { |p| p['id'] == @player.id }
    assert item, 'der neue Antrag muss in der Liste stehen'
    assert_equal License::REQUESTED, item['current_status']['license_status_id']
    assert_not(body['other_players'].any? { |p| p['id'] == @player.id })
  end

  # Die SBK genehmigt aus der Lizenzliste der Liga. Stand dort die alte
  # Lizenz, fiel der Spieler als „Transfer" aus dem Statusfilter und der neue
  # Antrag war fuer den Verband unsichtbar.
  test 'der neue Antrag steht in der Lizenzliste der Liga' do
    request_new_license

    row = League.licenses_for([@league]).fetch(@league.id, [])
                .flat_map { |t| t[:players] }
                .find { |p| p[:id] == @player.id }
    assert row, 'die SBK muss den Antrag in der Liste sehen'
    assert_equal License::REQUESTED, row[:team_license][:last_status_id].to_i
  end

  test 'nach der Genehmigung bleibt die alte Lizenz unberuehrt und die neue gilt' do
    fresh = request_new_license
    approve(fresh)

    @player.reload
    old = @player.licenses.find { |l| l['id'] == 'alt' }
    assert_equal License::TRANSFER, License.current_status_id(old)
    assert_equal fresh['id'], @player.license_for_team(@team.id)['id']
    assert @player.eligible_for_team?(@team.id, season_id: @league.season_id),
           'eine Sperre ueber X Spiele muss wieder abzaehlen'

    login_as(@vm)
    item = team_licenses['current_requests'].find { |p| p['id'] == @player.id }
    assert_equal License::APPROVED, item['current_status']['license_status_id']
  end

  test 'nach der Genehmigung warnt die Aufstellung nicht mehr' do
    approve(request_new_license)
    game = build_game

    post "/api/v2/user/games/#{game.id}/lineup/home/add_player",
         params: { player_id: @player.id, trikot_number: 7 }

    assert_response :success
    assert_nil JSON.parse(response.body)['warning']
  end

  test 'das Spielsekretariat sieht die neue Lizenz' do
    approve(request_new_license)
    game = build_game
    _link, token = GameDaySecretaryLink.generate!(game_days: [game.game_day], created_by: @admin)
    post '/api/v2/logout'

    get "/api/v2/user/team/#{@team.id}/licenses",
        params: { secretary_token: token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    item = JSON.parse(response.body)['current_requests'].find { |p| p['id'] == @player.id }
    assert item, 'der Spieler muss im Kader stehen'
    assert_equal License::APPROVED, item['current_status']['license_status_id']
  end

  test 'die Spielerliste des Vereins zeigt den Status der neuen Lizenz' do
    approve(request_new_license)
    login_as(@vm)

    get '/api/v2/admin/vm/players.json', params: { club_id: @club.id }

    assert_response :success
    row = JSON.parse(response.body).find { |p| p['id'] == @player.id }
    assert_equal License::APPROVED, row['current_license_status_id']
    assert_equal [License::APPROVED], row['current_licenses'].pluck('license_status_id')
  end
end
