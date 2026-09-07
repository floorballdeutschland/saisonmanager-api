require 'test_helper'

# Sperren in den Lizenzlisten, die NICHT der Verband liest (#605 zog nur die
# Verbandsansichten nach).
#
# Der Kern ist derselbe wie dort: Eine Sperre mit dem Geltungsbereich
# „Wettbewerb" oder „Liga" steht nicht in der Lizenzhistorie, weil dieselbe
# Lizenz in der Liga gesperrt und im Pokal erteilt sein kann. Wer nur die
# History liest, sieht sie gar nicht -- am Spieltisch stand der Gesperrte
# deshalb weiter als spielberechtigt, und in der Antragsuebersicht des Vereins
# auf „erteilt".
class LicenseListsSuspensionTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @admin = create(:user, :admin)
    @go = create(:game_operation)
    @liga = create(:league, :current_season, game_operation: @go, league_modus: 'league',
                                            age_group: 'Herren', field_size: 'GF')
    @pokal = create(:league, :current_season, game_operation: @go, league_modus: 'cup',
                                              age_group: 'Herren', field_size: 'GF')
    @club = create(:club, game_operation: @go)
    @arena = create(:arena)

    @home = create(:team, league: @liga, club: @club, cup_leagues: [@pokal.id])
    @guest = create(:team, league: @liga, club: @club)

    @liga_game_day = create(:game_day, league: @liga, arena: @arena, club: @club)
    @liga_game = create(:game, game_day: @liga_game_day, home_team: @home, guest_team: @guest)

    @pokal_game_day = create(:game_day, league: @pokal, arena: @arena, club: @club)
    @pokal_game = create(:game, game_day: @pokal_game_day, home_team: @home, guest_team: @guest)

    @player = create(:player, first_name: 'Gesperrte', last_name: 'Person',
                              clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                              with_licenses: [{ team: @home, status: License::APPROVED }])
  end

  # --- Oeffentliche Lizenzliste eines Spiels ------------------------------

  test 'die Lizenzliste des Spiels nennt eine Wettbewerbssperre' do
    suspend_competition!

    entry = public_list_entry(@liga_game)

    assert_equal 'gesperrt', entry['license_status']
    assert_equal "Herren Großfeld, Ligaspielbetrieb und DM/Endrunde, #{@go.name}",
                 entry['suspension_scope']
  end

  # Am Spieltisch gehoert der Geltungsbereich hin, die Begruendung nicht --
  # dieselbe Grenze wie im Kaderdialog des Sekretariats.
  test 'die Lizenzliste des Spiels nennt die Begruendung der Sperre nicht' do
    suspend_competition!(reason: 'Unsportliches Verhalten')

    entry = public_list_entry(@liga_game)

    assert_not entry.key?('reason')
    assert_not_includes entry.to_s, 'Unsportliches'
  end

  test 'im Pokal gilt dieselbe Lizenz weiter' do
    suspend_competition!

    entry = public_list_entry(@pokal_game)

    assert_equal 'erteilt', entry['license_status']
    assert_nil entry['suspension_scope']
  end

  # Vor dieser Aenderung fiel die Zeile ganz aus der Liste: Der Status 9 steht
  # bei einer Mannschaftssperre in der History, und gefiltert wurde auf
  # erteilt/beantragt. Das Sekretariat sah dann nicht „gesperrt", sondern gar
  # nichts -- nicht unterscheidbar von „hat keine Lizenz".
  test 'eine Mannschaftssperre laesst die Zeile stehen' do
    @player.suspend!(user_id: @admin.id, team_id: @home.id, valid_until: Date.current + 30,
                     scope: { kind: PlayerSuspension::SCOPE_TEAM })

    entry = public_list_entry(@liga_game)

    assert_equal 'gesperrt', entry['license_status']
  end

  test 'eine abgelaufene Sperre steht der Lizenz nicht mehr entgegen' do
    @player.suspend!(user_id: @admin.id, valid_from: Date.current - 10, valid_until: Date.current - 1,
                     scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal 'erteilt', public_list_entry(@liga_game)['license_status']
  end

  # --- Lizenzlisten des Spielsekretariats --------------------------------

  # Dieselbe Mannschaft tritt am selben Tag in derselben Halle in Liga und
  # Pokal an; ihre Lizenzliste steht dann unter beiden Ueberschriften. Ein
  # fertiges „gesperrt" waere unter einer von beiden falsch, deshalb nennt die
  # Antwort die betroffenen Ligen.
  test 'das Sekretariat bekommt die betroffenen Ligen je Zeile' do
    suspend_competition!

    entry = secretary_entry([@liga_game_day, @pokal_game_day])

    assert_equal [@liga.id], entry['suspended_league_ids']
    assert_equal 'erteilt', entry['license_status'], 'der gespeicherte Status bleibt erteilt'
    assert entry['suspension_scope'].present?
  end

  test 'ohne Sperre bleibt die Liste des Sekretariats unveraendert' do
    entry = secretary_entry([@liga_game_day])

    assert_equal [], entry['suspended_league_ids']
    assert_nil entry['suspension_scope']
    assert_equal 'erteilt', entry['license_status']
  end

  # --- Antragsuebersicht des Vereins -------------------------------------

  test 'die Vereinsansicht nennt Geltungsbereich und Dauer, aber nicht den Grund' do
    suspend_competition!(reason: 'Unsportliches Verhalten')
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/user/team/#{@home.id}/licenses"

    assert_response :success
    item = JSON.parse(response.body)['current_requests']
               .find { |i| i['id'] == @player.id }
    sperre = item['suspension']

    assert sperre.present?, 'die Zeile muss die Sperre mitbringen'
    assert sperre['scope_summary'].present?
    assert_equal (Date.current + 30).to_s, sperre['valid_until']
    assert_not sperre.key?('reason')
  end

  test 'ohne Sperre bleibt die Vereinsansicht ohne Sperrangabe' do
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/user/team/#{@home.id}/licenses"

    assert_response :success
    item = JSON.parse(response.body)['current_requests']
               .find { |i| i['id'] == @player.id }

    assert item.key?('suspension'), 'das Feld gehoert in jede Zeile, sonst ist es nicht auswertbar'
    assert_nil item['suspension']
  end

  private

  def suspend_competition!(reason: nil)
    @player.suspend!(user_id: @admin.id, valid_until: Date.current + 30, reason:,
                     scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
  end

  def public_list_entry(game)
    token = Rails.application.message_verifier('license_list').generate(
      { game_id: game.id, expires_at: 72.hours.from_now.iso8601 }, expires_in: 72.hours
    )
    get '/api/v2/public/license_list', params: { token: }
    assert_response :success

    JSON.parse(response.body)['home_team_licenses']
        .find { |e| e['name'] == "#{@player.first_name} #{@player.last_name}" }
  end

  def secretary_entry(game_days)
    _link, raw_token = GameDaySecretaryLink.generate!(game_days:, created_by: @admin)
    get '/api/v2/public/secretary', params: { token: raw_token }
    assert_response :success

    JSON.parse(response.body).dig('license_lists', @home.id.to_s, 'players')
        .find { |e| e['name'] == "#{@player.first_name} #{@player.last_name}" }
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
