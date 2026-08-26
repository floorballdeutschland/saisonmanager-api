require 'test_helper'

# Spielsekretariats-Link: Vereins- und Teammanager:innen geben ihn selbst aus,
# und er deckt alle Spieltage ab, die am selben Tag in derselben Halle laufen.
# Das Sekretariat sitzt pro Halle am Tisch, nicht pro Liga.
class GameDaySecretaryLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @go = create(:game_operation)
    @other_go = create(:game_operation)
    @arena = create(:arena, name: 'Sporthalle Nord')
    @date = 20.days.from_now.to_date.to_s

    @host_club = create(:club)
    @guest_club = create(:club)

    @league = create(:league, game_operation: @go)
    @game_day = create_game_day(@league, @host_club)
    @home = create(:team, league: @league, club: @host_club)
    @guest = create(:team, league: @league, club: @guest_club)
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest, start_time: '14:00')
  end

  # --- Berechtigung ----------------------------------------------------------

  test 'Vereinsmanager des Ausrichters darf einen Link erzeugen' do
    login(create(:user, :vm, club_id: @host_club.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :created
    body = JSON.parse(response.body)
    assert_match %r{/spielsekretariat\?token=}, body['url']
    assert_equal [@game_day.id], body['game_day_ids']
  end

  test 'Vereinsmanager des Gastvereins bekommt 403' do
    login(create(:user, :vm, club_id: @guest_club.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :forbidden
    assert_equal 0, GameDaySecretaryLink.count,
                 'am Sekretariatstisch sitzt der Ausrichter, nicht der Gast'
  end

  test 'Teammanager der Heimmannschaft darf einen Link erzeugen' do
    login(create(:user, :tm, team_id: @home.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :created
  end

  test 'Teammanager der Gastmannschaft bekommt 403' do
    login(create(:user, :tm, team_id: @guest.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :forbidden
    assert_equal 0, GameDaySecretaryLink.count
  end

  # Eine Spielgemeinschaft steht mit einem Verein in `club_id` und ihren
  # Partnervereinen in `syndicate_clubs`. Richtet sie unter dem Partner aus,
  # trägt der Spieltag dessen ID – ein Vergleich nur über `club_id` sperrte sie
  # aus ihrer eigenen Halle aus.
  test 'Teammanager einer Spielgemeinschaft darf am Spieltag des Partnervereins' do
    partner = create(:club)
    sg = create(:team, league: @league, club: @host_club,
                       syndicate: true, syndicate_clubs: [partner.id])
    day = create_game_day(@league, partner)
    Game.create!(game_day: day, home_team: sg, guest_team: @guest, start_time: '12:00')
    login(create(:user, :tm, team_id: sg.id))

    post "/api/v2/user/game_days/#{day.id}/secretary_link"

    assert_response :created
  end

  test 'SBK des Spielbetriebs darf einen Link erzeugen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :created
  end

  test 'SBK eines fremden Spielbetriebs bekommt 403' do
    login(create(:user, :sbk_scoped, game_operation_id: @other_go.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :forbidden
    assert_equal 0, GameDaySecretaryLink.count
  end

  test 'Vereinsmanager eines unbeteiligten Vereins bekommt 403' do
    login(create(:user, :vm, club_id: create(:club).id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :forbidden
    assert_equal 0, GameDaySecretaryLink.count
  end

  # --- Hallenweiter Umfang ---------------------------------------------------

  test 'Link deckt alle Spieltage derselben Halle am selben Tag ab' do
    second = build_parallel_game_day(@go)
    login(create(:user, :vm, club_id: @host_club.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :created
    ids = JSON.parse(response.body)['game_day_ids']
    assert_equal [@game_day.id, second.id].sort, ids.sort,
                 'beide Ligen in derselben Halle am selben Tag gehören in denselben Link'
  end

  test 'Spieltag derselben Halle an einem anderen Tag bleibt außen vor' do
    other_day = create_game_day(create(:league, game_operation: @go), @host_club,
                                date: (Date.parse(@date) + 7).to_s)
    login(create(:user, :vm, club_id: @host_club.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    ids = JSON.parse(response.body)['game_day_ids']
    assert_not_includes ids, other_day.id
  end

  test 'Spieltag ohne Halle steht für sich allein' do
    @game_day.update!(arena: nil)
    create_game_day(create(:league, game_operation: @go), @host_club, arena: nil)
    login(create(:user, :vm, club_id: @host_club.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_equal [@game_day.id], JSON.parse(response.body)['game_day_ids'],
                 'ohne arena_id gibt es keine Halle, über die gruppiert werden könnte'
  end

  test 'fremde Liga in derselben Halle kommt nicht in den Link' do
    build_foreign_game_day

    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    ids = JSON.parse(response.body)['game_day_ids']
    assert_equal [@game_day.id], ids,
                 'eine gemeinsam genutzte Halle darf keinen Zugriff auf fremde Ligen öffnen'
  end

  test 'SBK-Umfang endet am fremden Spielbetrieb derselben Halle' do
    foreign_day = build_parallel_game_day(@other_go)
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    ids = JSON.parse(response.body)['game_day_ids']
    assert_not_includes ids, foreign_day.id
  end

  test 'Teammanager bekommt nur den Spieltag der eigenen Mannschaft' do
    second = build_parallel_game_day(@go)
    login(create(:user, :tm, team_id: @home.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_equal [@game_day.id], JSON.parse(response.body)['game_day_ids'],
                 'die zweite Liga derselben Halle gehört nicht zu den Mannschaften dieses TM'
    assert_not_nil second
  end

  test 'Admin bekommt auch die fremde Liga derselben Halle in den Link' do
    foreign_day = build_parallel_game_day(@other_go)
    login(create(:user, :admin))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    ids = JSON.parse(response.body)['game_day_ids']
    assert_equal [@game_day.id, foreign_day.id].sort, ids.sort
  end

  # --- Token-Wirkung ---------------------------------------------------------

  test 'Token gilt für die Spiele aller abgedeckten Spieltage' do
    second = build_parallel_game_day(@go)
    second_game = second.games.first
    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"
    token = JSON.parse(response.body)['token']
    reset!

    get '/api/v2/public/secretary', params: { token: token }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body['game_days'].size
    assert_includes body['games'].map { |g| g['id'] }, second_game.id
    # Welcher der beiden Spieltage vorn steht, hängt an der Sortierung nach
    # Datum und Liganame und ist für die Zusage ohne Belang: game_day muss der
    # erste der Liste sein, damit ein älteres Frontend denselben sieht wie ein
    # neues. Auf @game_day zu prüfen hieße, die Liganamen der Factory-Sequenz
    # festzuschreiben.
    assert_equal body['game_days'].first['id'], body.dig('game_day', 'id'),
                 'game_day bleibt für ältere Frontends der erste abgedeckte Spieltag'
  end

  test 'Lizenzlisten umfassen die Mannschaften aller abgedeckten Spieltage' do
    second = build_parallel_game_day(@go)
    second_home = second.games.first.home_team
    create(:player, with_licenses: [{ team: second_home, status: License::APPROVED }])
    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"
    token = JSON.parse(response.body)['token']
    reset!

    get '/api/v2/public/secretary', params: { token: token }

    lists = JSON.parse(response.body)['license_lists']
    assert_includes lists.keys, second_home.id.to_s
    assert_equal 1, lists[second_home.id.to_s]['players'].size
  end

  # --- Schreibzugriff --------------------------------------------------------

  # Der Umfang des Tokens entscheidet sich an der Zuordnungstabelle, nicht an
  # der JSON-Antwort des Erzeugens. Eine schreibende Action beweist das.
  test 'Token schreibt auf allen abgedeckten Spieltagen, nicht auf der fremden Liga' do
    second = build_parallel_game_day(@go)
    foreign = build_parallel_game_day(@other_go)
    _link, token = GameDaySecretaryLink.generate!(game_days: [@game_day, second],
                                                  created_by: create(:user, :admin))

    post "/api/v2/user/games/#{second.games.first.id}/set_field",
         params: { secretary_token: token, game: { audience: '120' } }
    assert_response :success
    assert_equal 120, second.games.first.reload.audience

    post "/api/v2/user/games/#{foreign.games.first.id}/set_field",
         params: { secretary_token: token, game: { audience: '120' } }
    assert_response :forbidden
    assert_nil foreign.games.first.reload.audience
  end

  # --- Neuausgabe ------------------------------------------------------------

  test 'Neuausgabe entzieht dem alten Link genau die neu vergebenen Spieltage' do
    second = build_foreign_game_day
    _old_link, old_token = GameDaySecretaryLink.generate!(game_days: [@game_day, second],
                                                          created_by: create(:user, :admin))

    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"
    assert_response :created
    reset!

    # Der VM darf nur seinen eigenen Spieltag neu vergeben. Der alte Link
    # verliert deshalb genau diesen und behält die fremde Liga – sonst stünde
    # deren Sekretariat mitten am Spieltag ohne Token da, ohne Ersatz.
    get '/api/v2/public/secretary', params: { token: old_token }
    assert_response :success
    remaining_ids = JSON.parse(response.body)['game_days'].map { |gd| gd['id'] }
    assert_equal [second.id], remaining_ids
  end

  test 'Neuausgabe entfernt einen Link, dem kein Spieltag mehr bleibt' do
    _old_link, old_token = GameDaySecretaryLink.generate!(game_days: [@game_day],
                                                          created_by: create(:user, :admin))

    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"
    reset!

    get '/api/v2/public/secretary', params: { token: old_token }
    assert_response :gone
    assert_equal 1, GameDaySecretaryLink.count, 'der leergeräumte Link darf nicht zurückbleiben'
  end

  # --- Übersicht -------------------------------------------------------------

  test 'Übersicht gruppiert nach Halle und Tag und nennt den aktiven Link' do
    second = build_parallel_game_day(@go)
    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    get '/api/v2/user/secretary_game_days'

    assert_response :success
    groups = JSON.parse(response.body)
    assert_equal 1, groups.size
    group = groups.first
    assert_equal 'Sporthalle Nord', group['arena']
    assert_equal @date, group['date']
    assert_equal [@game_day.id, second.id].sort, group['game_days'].map { |gd| gd['id'] }.sort
    assert_equal [], group['other_game_days_in_hall']
    assert_not_nil group.dig('link', 'expires_at')
  end

  test 'Übersicht weist fremde Spieltage derselben Halle getrennt aus' do
    foreign_day = build_foreign_game_day

    login(create(:user, :vm, club_id: @host_club.id))
    get '/api/v2/user/secretary_game_days'

    group = JSON.parse(response.body).first
    own_ids = group['game_days'].map { |gd| gd['id'] }
    foreign_ids = group['other_game_days_in_hall'].map { |gd| gd['id'] }
    assert_equal [@game_day.id], own_ids
    assert_equal [foreign_day.id], foreign_ids,
                 'der Verein soll sehen, dass die Halle noch anderweitig belegt ist'
  end

  test 'Übersicht ohne VM/TM-Rolle ist leer' do
    login(create(:user, :admin))

    get '/api/v2/user/secretary_game_days'

    assert_response :success
    assert_equal [], JSON.parse(response.body),
                 'Admin und SBK erzeugen ihre Links in der Spielplan-Verwaltung'
  end

  test 'Übersicht des Gastvereins nennt den Auswärtsspieltag nicht' do
    login(create(:user, :vm, club_id: @guest_club.id))

    get '/api/v2/user/secretary_game_days'

    assert_response :success
    assert_equal [], JSON.parse(response.body),
                 'der Gast soll fremde Spieltage weder sehen noch vergeben können'
  end

  test 'Übersicht des Gastvereins bleibt auch als Teammanager leer' do
    login(create(:user, :tm, team_id: @guest.id))

    get '/api/v2/user/secretary_game_days'

    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  # Der Spielplan-Import legt Spieltage ohne Halle und ohne Ausrichter an. Ohne
  # Rückfall auf die Heimmannschaft käme für die niemand mehr an den Link, und
  # diese Seite ist der einzige Weg des Vereins dorthin.
  test 'Spieltag ohne Ausrichter bleibt für den Verein der Heimmannschaft erreichbar' do
    @game_day.update!(club: nil)
    login(create(:user, :vm, club_id: @host_club.id))

    get '/api/v2/user/secretary_game_days'

    assert_response :success
    ids = JSON.parse(response.body).flat_map { |g| g['game_days'].map { |gd| gd['id'] } }
    assert_includes ids, @game_day.id

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :created
  end

  test 'Spieltag ohne Ausrichter bleibt dem Gastverein verschlossen' do
    @game_day.update!(club: nil)
    login(create(:user, :vm, club_id: @guest_club.id))

    get '/api/v2/user/secretary_game_days'

    assert_equal [], JSON.parse(response.body)

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :forbidden
  end

  test 'zwei Spieltage ohne Halle am selben Tag bleiben getrennte Gruppen' do
    @game_day.update!(arena: nil)
    second = create_game_day(create(:league, game_operation: @go), @host_club, arena: nil)
    login(create(:user, :vm, club_id: @host_club.id))

    get '/api/v2/user/secretary_game_days'

    ids = JSON.parse(response.body).flat_map { |g| g['game_days'].map { |gd| gd['id'] } }
    assert_equal [@game_day.id, second.id].sort, ids.sort,
                 'ohne Halle lässt sich nicht gruppieren – kein Spieltag darf dabei verloren gehen'
  end

  test 'Übersicht nennt die abgedeckten Spieltage des aktiven Links' do
    second = build_parallel_game_day(@go)
    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    get '/api/v2/user/secretary_game_days'

    link_ids = JSON.parse(response.body).first.dig('link', 'game_day_ids')
    assert_equal [@game_day.id, second.id].sort, link_ids.sort
  end

  test 'Übersicht zeigt einen Spieltag von gestern noch an' do
    @game_day.update!(date: 1.day.ago.to_date.to_s)
    login(create(:user, :vm, club_id: @host_club.id))

    get '/api/v2/user/secretary_game_days'

    assert_equal 1, JSON.parse(response.body).size,
                 'während der 72-Stunden-Gültigkeit muss ein Link neu ausgegeben werden können'
  end

  # `game_days.date` ist Text, und die Altdaten sind nicht durchgängig sauber.
  # Der Verein kommt nur über diese Seite an seinen Link, also darf ein
  # unbrauchbares Datum den Spieltag weder verschwinden lassen noch die Liste
  # mitreißen.
  test 'Spieltag mit leerem Datum verschwindet nicht aus der Übersicht' do
    @game_day.update_column(:date, '')
    login(create(:user, :vm, club_id: @host_club.id))

    get '/api/v2/user/secretary_game_days'

    assert_response :success
    ids = JSON.parse(response.body).flat_map { |g| g['game_days'].map { |gd| gd['id'] } }
    assert_includes ids, @game_day.id,
                    "TO_DATE('') ergibt ein Datum vor Christus und fiele lautlos aus dem Fenster"
  end

  test 'unbrauchbares Datum reißt die Übersicht nicht in einen Serverfehler' do
    @game_day.update_column(:date, 'TBD')
    login(create(:user, :vm, club_id: @host_club.id))

    get '/api/v2/user/secretary_game_days'

    assert_response :success
    ids = JSON.parse(response.body).flat_map { |g| g['game_days'].map { |gd| gd['id'] } }
    assert_includes ids, @game_day.id
  end

  test 'Spieltag ohne verwertbares Datum wird ohne Hallennamen ausgewiesen' do
    @game_day.update_column(:date, '')
    login(create(:user, :vm, club_id: @host_club.id))

    get '/api/v2/user/secretary_game_days'

    group = JSON.parse(response.body).first
    assert_nil group['arena_id']
    assert_nil group['arena'],
               'Name ohne ID widerspräche der Zusage, die das Frontend als Union typisiert'
  end

  test 'Übersicht zeigt keine weit zurückliegenden Spieltage' do
    @game_day.update!(date: 30.days.ago.to_date.to_s)
    login(create(:user, :vm, club_id: @host_club.id))

    get '/api/v2/user/secretary_game_days'

    assert_equal [], JSON.parse(response.body)
  end

  test 'GET secretary_link liefert den Link auch über einen Nachbarspieltag' do
    second = build_parallel_game_day(@go)
    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    get "/api/v2/user/game_days/#{second.id}/secretary_link"

    assert_response :success
    body = JSON.parse(response.body)
    assert_not_nil body['expires_at']
    assert_equal [@game_day.id, second.id].sort, body['game_day_ids'].sort
  end

  test 'GET secretary_link meldet einen abgelaufenen Link als inaktiv' do
    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"
    GameDaySecretaryLink.covering([@game_day.id]).first.update_column(:expires_at, 1.hour.ago)

    get "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :success
    assert_equal false, JSON.parse(response.body)['active']
  end

  # --- Spieltag löschen ------------------------------------------------------

  test 'gelöschter Spieltag entfernt nur seine Zuordnung, nicht den Link' do
    second = build_parallel_game_day(@go)
    link, token = GameDaySecretaryLink.generate!(game_days: [@game_day, second], created_by: create(:user, :admin))

    second.games.destroy_all
    second.destroy!

    assert GameDaySecretaryLink.exists?(link.id)
    assert_equal [@game_day.id], link.reload.game_days.pluck(:id)
    assert_not_nil GameDaySecretaryLink.find_by_token(token)
  end

  test 'Link ohne verbleibende Spieltage gilt als ungültig' do
    _link, token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))
    @game_day.games.destroy_all
    @game_day.destroy!

    get '/api/v2/public/secretary', params: { token: token }

    assert_response :gone,
                    'sonst käme eine 200 ohne Spieltag zurück und die Seite liefe in einen Fehler'
  end

  test 'ein Link ohne Spieltag lässt sich gar nicht erst anlegen' do
    assert_raises(ActiveRecord::RecordInvalid) do
      GameDaySecretaryLink.create!(
        created_by: create(:user, :admin),
        token_digest: 'x' * 64,
        expires_at: 1.hour.from_now
      )
    end
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def create_game_day(league, club, date: @date, arena: @arena)
    GameDay.create!(league: league, arena: arena, club: club, number: 1, date: date)
  end

  # Zweiter Spieltag in derselben Halle am selben Tag – die Konstellation, um
  # die es geht: zwei Ligen hintereinander, ein Sekretariat.
  def build_parallel_game_day(game_operation)
    league = create(:league, game_operation: game_operation)
    day = create_game_day(league, @host_club)
    Game.create!(game_day: day,
                 home_team: create(:team, league: league, club: @host_club),
                 guest_team: create(:team, league: league, club: @guest_club),
                 start_time: '16:00')
    day
  end

  # Ebenfalls dieselbe Halle am selben Tag, aber mit fremdem Ausrichter und
  # fremden Mannschaften: nichts daran gehört dem Verein aus dem Setup.
  def build_foreign_game_day
    club = create(:club)
    league = create(:league, game_operation: @other_go)
    day = create_game_day(league, club)
    Game.create!(game_day: day,
                 home_team: create(:team, league: league, club: club),
                 guest_team: create(:team, league: league, club: create(:club)),
                 start_time: '18:00')
    day
  end
end
