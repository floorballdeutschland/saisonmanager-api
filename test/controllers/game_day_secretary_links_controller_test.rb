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

  test 'Vereinsmanager eines beteiligten Gastvereins darf einen Link erzeugen' do
    login(create(:user, :vm, club_id: @guest_club.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :created
  end

  test 'Teammanager einer beteiligten Mannschaft darf einen Link erzeugen' do
    login(create(:user, :tm, team_id: @home.id))

    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    assert_response :created
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
    foreign_club = create(:club)
    foreign_league = create(:league, game_operation: @other_go)
    foreign_day = create_game_day(foreign_league, foreign_club)
    Game.create!(game_day: foreign_day,
                 home_team: create(:team, league: foreign_league, club: foreign_club),
                 guest_team: create(:team, league: foreign_league, club: create(:club)))

    login(create(:user, :vm, club_id: @host_club.id))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"

    ids = JSON.parse(response.body)['game_day_ids']
    assert_equal [@game_day.id], ids,
                 'eine gemeinsam genutzte Halle darf keinen Zugriff auf fremde Ligen öffnen'
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
    assert_equal @game_day.id, body.dig('game_day', 'id'),
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

  # --- Neuausgabe ------------------------------------------------------------

  test 'Neuausgabe ersetzt jeden laufenden Link, der einen der Spieltage abdeckt' do
    second = build_parallel_game_day(@other_go)
    sbk = create(:user, :sbk_scoped, game_operation_id: @other_go.id)
    _old_link, old_token = GameDaySecretaryLink.generate!(game_days: [second], created_by: sbk)

    login(create(:user, :admin))
    post "/api/v2/user/game_days/#{@game_day.id}/secretary_link"
    assert_response :created
    reset!

    # Der SBK-Link deckte nur seinen eigenen Spieltag ab; der Admin-Link deckt
    # beide ab und löst ihn deshalb ab. Bewusst so: für einen Spieltag darf nur
    # ein gültiger Token im Umlauf sein, sonst weiß niemand, welcher gilt.
    get '/api/v2/public/secretary', params: { token: old_token }
    assert_response :gone
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
    foreign_club = create(:club)
    foreign_league = create(:league, game_operation: @other_go)
    foreign_day = create_game_day(foreign_league, foreign_club)
    Game.create!(game_day: foreign_day,
                 home_team: create(:team, league: foreign_league, club: foreign_club),
                 guest_team: create(:team, league: foreign_league, club: create(:club)))

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
end
