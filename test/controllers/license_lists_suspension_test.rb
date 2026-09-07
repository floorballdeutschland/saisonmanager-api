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

    # Die Spieltage liegen auf heute: Massgeblich fuer das Sperrfenster ist das
    # Datum des SPIELTAGS, nicht der Tag des Abrufs.
    @liga_game_day = create(:game_day, league: @liga, arena: @arena, club: @club, date: Date.current.to_s)
    @liga_game = create(:game, game_day: @liga_game_day, home_team: @home, guest_team: @guest)

    @pokal_game_day = create(:game_day, league: @pokal, arena: @arena, club: @club, date: Date.current.to_s)
    @pokal_game = create(:game, game_day: @pokal_game_day, home_team: @home, guest_team: @guest)

    @player = create(:player, first_name: 'Gesperrte', last_name: 'Person',
                              clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                              with_licenses: [{ team: @home, status: License::APPROVED }])
    # Eine zweite, ungesperrte Person mit Lizenz derselben Mannschaft: Wird die
    # Sperre nicht je Spieler nachgeschlagen, traegt sie auch diese Zeile.
    @mitspieler = create(:player, first_name: 'Freie', last_name: 'Person',
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
    assert_equal "Herren Großfeld, Ligaspielbetrieb und DM/Endrunde, #{@go.name}",
                 entry['suspension_scope']
    # Der Status traegt die Sperre, sobald sie EINE der Ligen erfasst: Eine
    # Ansicht, die `suspended_league_ids` noch nicht auswertet, liest genau
    # dieses Feld und soll dann uebermarkieren statt „erteilt" zu behaupten.
    assert_equal 'gesperrt', entry['license_status']
    # Fuer die Feinentscheidung je Ueberschrift kommt der Status ohne Sperre
    # mit -- unter der Pokal-Ueberschrift gilt die Lizenz weiter.
    assert_equal 'erteilt', entry['base_license_status']
  end

  # Die Gegenrichtung: Sperre im Pokal, Liga frei. Ohne sie liesse sich die
  # Auswertung auf „die erste Liga entscheidet" verkuerzen, ohne dass ein Test
  # rot wird.
  test 'eine Pokalsperre trifft nur die Pokal-Ueberschrift' do
    @player.suspend!(user_id: @admin.id, valid_until: Date.current + 30,
                     scope: { kind: PlayerSuspension::SCOPE_LEAGUE, league: @pokal })

    entry = secretary_entry([@liga_game_day, @pokal_game_day])

    assert_equal [@pokal.id], entry['suspended_league_ids']
    assert_equal 'erteilt', entry['base_license_status']
    assert_equal 'erteilt', public_list_entry(@liga_game)['license_status']
    assert_equal 'gesperrt', public_list_entry(@pokal_game)['license_status']
  end

  # Der schwerste Fall aus dem CHANGELOG, und zwar am Spieltisch: Vor dieser
  # Aenderung fiel die Zeile bei einer Mannschaftssperre hier ganz heraus.
  test 'eine Mannschaftssperre steht am Spieltisch unter beiden Ueberschriften' do
    @player.suspend!(user_id: @admin.id, team_id: @home.id, valid_until: Date.current + 30,
                     scope: { kind: PlayerSuspension::SCOPE_TEAM })

    entry = secretary_entry([@liga_game_day, @pokal_game_day])

    # Eine Team-Sperre erfasst jeden Wettbewerb dieser Mannschaft, weil die
    # Lizenz ueber cup_leagues auch deren Pokalspiele deckt.
    assert_equal [@liga.id, @pokal.id].sort, entry['suspended_league_ids'].sort
    assert_equal 'gesperrt', entry['license_status']
    assert_equal 'erteilt', entry['base_license_status']
  end

  # Die spielerweite Sperre ist die migrierte Beantragungssperre und damit der
  # haeufigste Bestand. Sie schreibt den Status 9 in die Historie -- die Zeile
  # muss trotzdem stehen bleiben und in JEDEM Wettbewerb gesperrt sein.
  test 'eine spielerweite Sperre gilt in Liga und Pokal' do
    @player.suspend!(user_id: @admin.id, valid_until: Date.current + 30,
                     scope: { kind: PlayerSuspension::SCOPE_ALL })

    entry = secretary_entry([@liga_game_day, @pokal_game_day])

    assert_equal [@liga.id, @pokal.id].sort, entry['suspended_league_ids'].sort
    assert_equal 'alle Wettbewerbe', entry['suspension_scope']
    assert_equal 'gesperrt', public_list_entry(@liga_game)['license_status']
    assert_equal 'gesperrt', public_list_entry(@pokal_game)['license_status']
  end

  # Der normale Ausgang einer Sperre ist das Aufheben -- durch die Verwaltung
  # oder von selbst, wenn die Spiele abgesessen sind. Danach ist der Spieler
  # spielberechtigt, und zwar sofort.
  test 'eine aufgehobene Sperre steht der Lizenz nicht mehr entgegen' do
    suspension = suspend_competition!
    @player.lift_suspension!(suspension, user_id: @admin.id)

    assert_equal 'erteilt', public_list_entry(@liga_game)['license_status']
    entry = secretary_entry([@liga_game_day])
    assert_equal [], entry['suspended_league_ids']
    assert_equal 'erteilt', entry['license_status']

    login(create(:user, :vm, club_id: @club.id))
    assert_nil club_item['suspension']
  end

  test 'ohne Sperre bleibt die Liste des Sekretariats unveraendert' do
    entry = secretary_entry([@liga_game_day])

    assert_equal [], entry['suspended_league_ids']
    assert_nil entry['suspension_scope']
    assert_equal 'erteilt', entry['license_status']
  end

  # Die Sperre haengt am Spieler, nicht an der Mannschaft: Ein Fehlgriff in der
  # Nachschlagetabelle traefe sonst jede Zeile der Halle.
  test 'die Sperre bleibt an der gesperrten Person' do
    suspend_competition!

    entry = secretary_entry([@liga_game_day], @mitspieler)

    assert_equal [], entry['suspended_league_ids']
    assert_equal 'erteilt', entry['license_status']
    assert_nil public_list_entry(@liga_game, @mitspieler)['suspension_scope']
  end

  test 'auch die Gastmannschaft wird auf Sperren geprueft' do
    gast_spieler = create(:player, first_name: 'Gast', last_name: 'Person',
                                   clubs: [{ 'club_id' => @club.id, 'home_club' => true }],
                                   with_licenses: [{ team: @guest, status: License::APPROVED }])
    gast_spieler.suspend!(user_id: @admin.id, valid_until: Date.current + 30,
                          scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    entry = public_list(@liga_game, 'guest_team_licenses')
            .find { |e| e['name'] == name_of(gast_spieler) }

    assert_equal 'gesperrt', entry['license_status']
  end

  # Ohne Liga am Spieltag ist die Frage je Ueberschrift nicht zu beantworten --
  # dann entscheidet die Mannschaft. Sonst faerbte ein Datenfehler ausgerechnet
  # eine spielerweite Sperre auf „erteilt", und das ist die Richtung, in die
  # eine Lizenzliste nie irren darf. `suspended_league_ids` bleibt dabei leer,
  # weil es keine Liga gibt, auf die es zeigen koennte.
  test 'ohne Liga am Spieltag entscheidet die Mannschaft' do
    @player.suspend!(user_id: @admin.id, team_id: @home.id, valid_until: Date.current + 30,
                     scope: { kind: PlayerSuspension::SCOPE_TEAM })
    # `league_id` ist nullable; der Weg dahin ist ein Datenfehler, kein
    # regulaerer Zustand -- deshalb an den Validierungen vorbei.
    @liga_game_day.update_column(:league_id, nil)

    entry = secretary_entry([@liga_game_day])

    assert_equal 'gesperrt', entry['license_status']
    assert_equal [], entry['suspended_league_ids']
    assert entry['suspension_scope'].present?
  end

  # --- Das Datum des Spieltags, nicht der Tag des Abrufs ------------------

  # Der Link lebt 72 Stunden, und seit der Spieltagscheckliste wird die Liste
  # in der Vorbereitung geoeffnet. Wer am Vorabend nachsieht, muss die Sperre
  # des naechsten Tages sehen.
  test 'die Sperre des Spieltags gilt auch beim Blick am Vorabend' do
    morgen = Date.current + 1
    @liga_game_day.update!(date: morgen.to_s)
    @player.suspend!(user_id: @admin.id, valid_from: morgen, valid_until: morgen + 7,
                     scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal 'gesperrt', public_list_entry(@liga_game)['license_status']
    assert_equal [@liga.id], secretary_entry([@liga_game_day])['suspended_league_ids']
  end

  # Und die Gegenrichtung: Eine Sperre, die erst nach dem Spieltag begonnen
  # hat, gehoert nicht auf den Beleg dieses Spieltags.
  test 'eine erst spaeter beginnende Sperre steht nicht auf dem Beleg' do
    gestern = Date.current - 1
    @liga_game_day.update!(date: gestern.to_s)
    @player.suspend!(user_id: @admin.id, valid_from: Date.current, valid_until: Date.current + 7,
                     scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })

    assert_equal 'erteilt', public_list_entry(@liga_game)['license_status']
    assert_equal [], secretary_entry([@liga_game_day])['suspended_league_ids']
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
    assert_equal 'Herren Großfeld, Ligaspielbetrieb und DM/Endrunde, ' \
                 "#{@go.name}", sperre['scope_summary']
    assert_equal (Date.current + 30).to_s, sperre['valid_until']
    assert_not sperre.key?('reason')
  end

  test 'die Vereinsansicht nennt die Restspiele einer Sperre ueber Spiele' do
    @player.suspend!(user_id: @admin.id, games_total: 3,
                     scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
    login(create(:user, :vm, club_id: @club.id))

    sperre = club_item['suspension']

    assert_equal 3, sperre['games_total']
    assert_equal 3, sperre['remaining_games']
    assert_nil sperre['valid_until'], 'eine Sperre ueber Spiele braucht kein Enddatum'
  end

  # Eine Sperre auf die Pokalliga der Mannschaft: Die Lizenz gilt dort ueber
  # cup_leagues, die Stammliga allein beantwortet die Frage also nicht.
  test 'die Vereinsansicht sieht auch eine Sperre in der Pokalliga' do
    @player.suspend!(user_id: @admin.id, valid_until: Date.current + 30,
                     scope: { kind: PlayerSuspension::SCOPE_LEAGUE, league: @pokal })
    login(create(:user, :vm, club_id: @club.id))

    assert_equal @pokal.name, club_item['suspension']['scope_summary']
  end

  # Der Grund einer Sperre steht bei den Geltungsbereichen `all` und `team` in
  # der Lizenzhistorie, und die geht als ganzer Hash an Verein und Mannschaft.
  # Geprueft wird deshalb der gesamte Antwortkoerper und nicht das eine Feld,
  # das die Begruendung ohnehin nie trug.
  test 'die Begruendung einer Sperre erreicht den Verein nirgends' do
    @player.suspend!(user_id: @admin.id, team_id: @home.id, valid_until: Date.current + 30,
                     reason: 'Geheimer Grund XYZ',
                     scope: { kind: PlayerSuspension::SCOPE_TEAM })
    login(create(:user, :vm, club_id: @club.id))

    item = club_item

    assert_not_includes response.body, 'Geheimer Grund'
    # Auch nicht mittelbar: current_license_status loest `created_by` zu
    # Klarnamen und Benutzernamen der sperrenden Person auf.
    assert_not_includes response.body, @admin.user_name
    assert_equal 'gesperrt', item['current_status']['license_status']
    assert_nil item['current_status']['created_by_name']
    # Die Begruendung anderer Status bleibt: Warum ein Antrag abgelehnt wurde,
    # ist genau die Auskunft, die der Verein braucht.
    sperr_eintrag = item['team_license']['history']
                    .find { |h| h['license_status_id'].to_i == License::SUSPENDED }
    assert sperr_eintrag.present?, 'der Sperr-Eintrag selbst bleibt sichtbar'
    assert_not sperr_eintrag.key?('reason')
  end

  test 'die Begruendung einer Ablehnung bleibt dem Verein erhalten' do
    @player.licenses.first['history'] << { 'license_status_id' => License::DENIED,
                                           'reason' => 'Ausweis fehlt',
                                           'created_at' => Time.current.iso8601 }
    @player.save!
    login(create(:user, :vm, club_id: @club.id))

    assert_includes response_body_of_club_view, 'Ausweis fehlt'
  end

  # Am Spieltisch erscheint der Geltungsbereich, nie die Begruendung -- der
  # Link ist oeffentlich und ohne Anmeldung erreichbar.
  test 'die Begruendung erreicht auch die Listen des Spieltags nicht' do
    @player.suspend!(user_id: @admin.id, team_id: @home.id, valid_until: Date.current + 30,
                     reason: 'Geheimer Grund XYZ',
                     scope: { kind: PlayerSuspension::SCOPE_TEAM })

    public_list_entry(@liga_game)
    assert_not_includes response.body, 'Geheimer Grund'

    secretary_entry([@liga_game_day])
    assert_not_includes response.body, 'Geheimer Grund'
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

  def response_body_of_club_view
    get "/api/v2/user/team/#{@home.id}/licenses"
    assert_response :success
    response.body
  end

  def suspend_competition!(reason: nil)
    @player.suspend!(user_id: @admin.id, valid_until: Date.current + 30, reason:,
                     scope: { kind: PlayerSuspension::SCOPE_COMPETITION, league: @liga })
  end

  def public_list(game, key = 'home_team_licenses')
    token = Rails.application.message_verifier('license_list').generate(
      { game_id: game.id, expires_at: 72.hours.from_now.iso8601 }, expires_in: 72.hours
    )
    get '/api/v2/public/license_list', params: { token: }
    assert_response :success

    JSON.parse(response.body)[key]
  end

  # Eine fehlende Zeile ist einer der beiden Fehler, die dieser PR behebt --
  # sie soll sich als solche melden und nicht als NoMethodError am nil.
  def public_list_entry(game, player = @player)
    entry = public_list(game).find { |e| e['name'] == name_of(player) }
    assert entry.present?, "Zeile fuer #{name_of(player)} fehlt in der Lizenzliste"
    entry
  end

  def secretary_entries(game_days)
    _link, raw_token = GameDaySecretaryLink.generate!(game_days:, created_by: @admin)
    get '/api/v2/public/secretary', params: { token: raw_token }
    assert_response :success

    JSON.parse(response.body).dig('license_lists', @home.id.to_s, 'players')
  end

  def secretary_entry(game_days, player = @player)
    entry = secretary_entries(game_days).find { |e| e['name'] == name_of(player) }
    assert entry.present?, "Zeile fuer #{name_of(player)} fehlt in der Lizenzliste des Sekretariats"
    entry
  end

  def club_item(player = @player)
    get "/api/v2/user/team/#{@home.id}/licenses"
    assert_response :success

    JSON.parse(response.body)['current_requests'].find { |i| i['id'] == player.id }
  end

  def name_of(player)
    "#{player.first_name} #{player.last_name}"
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
