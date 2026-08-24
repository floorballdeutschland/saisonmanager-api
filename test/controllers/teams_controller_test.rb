require 'test_helper'

class TeamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club)
    @team = create(:team, league: @league, club: @club, contact_email: 'team@example.org')
  end

  test 'admin_get_team erlaubt dem SBK des Spielbetriebs den Zugriff inkl. Kontaktdaten' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
    assert_equal 'team@example.org', JSON.parse(response.body)['contact_email']
  end

  test 'admin_get_team sperrt SBK eines fremden Spielbetriebs' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :forbidden
  end

  test 'admin_get_team erlaubt dem TM des Teams den Zugriff' do
    login(create(:user, :tm, team_id: @team.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
  end

  test 'admin_get_team erlaubt dem VM des Vereins den Zugriff' do
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/teams/#{@team.id}"

    assert_response :success
  end

  test 'destroy löscht ein Team ohne Spieler/Spiele als Admin' do
    login(create(:user, :admin))

    assert_difference('Team.count', -1) do
      delete "/api/v2/admin/teams/#{@team.id}"
    end

    assert_response :no_content
  end

  test 'destroy sperrt VM des Vereins (keine Löschberechtigung)' do
    login(create(:user, :vm, club_id: @club.id))

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :forbidden
    assert Team.exists?(@team.id)
  end

  test 'destroy sperrt SBK eines fremden Spielbetriebs' do
    other_sa = create(:state_association)
    other_go = create(:game_operation, state_association_id: other_sa.id)
    login(create(:user, :sbk_scoped, game_operation_id: other_go.id))

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :forbidden
    assert Team.exists?(@team.id)
  end

  test 'destroy erlaubt dem SBK des richtigen Spielbetriebs das Löschen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    assert_difference('Team.count', -1) do
      delete "/api/v2/admin/teams/#{@team.id}"
    end

    assert_response :no_content
  end

  test 'destroy lehnt Löschung ab, wenn noch Spieler/Lizenzen zugeordnet sind' do
    login(create(:user, :admin))
    create(:player, with_licenses: [{ team: @team }])

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Spieler/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn noch Spiele existieren' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    guest = create(:team, league: @league, club: @club)
    Game.create!(
      game_day:,
      home_team: @team,
      guest_team: guest,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Spiele/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn das Team nur als Gastteam an einem Spiel beteiligt ist' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    home = create(:team, league: @league, club: @club)
    Game.create!(
      game_day:,
      home_team: home,
      guest_team: @team,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Spiele/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn noch Sperren dem Team zugeordnet sind' do
    login(create(:user, :admin))
    player = create(:player)
    PlayerSuspension.create!(
      player:, team_id: @team.id, valid_from: '2026-01-01', valid_until: '2026-06-30'
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Sperren/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'destroy lehnt Löschung ab, wenn noch Schiedsrichter-Feedback für das Team existiert' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    home = create(:team, league: @league, club: @club)
    guest = create(:team, league: @league, club: @club)
    game = Game.create!(
      game_day:,
      home_team: home,
      guest_team: guest,
      started: false,
      ended: false,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
    RefereeFeedback.create!(
      game:, team: @team, line_rating: 5, communication_rating: 5
    )

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/Feedback/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'stats liefert Torschützen/Spiele auch für ein Team aus einer abgelaufenen Saison' do
    login(create(:user, :admin))
    archived_league = create(:league, :archived_season, game_operation: @go)
    archived_team = create(:team, league: archived_league, club: @club)
    guest = create(:team, league: archived_league, club: @club)
    arena = create(:arena)
    game_day = GameDay.create!(league: archived_league, arena:, club: @club, number: 1, date: '2003-01-01')
    Game.create!(
      game_day:,
      home_team: archived_team,
      guest_team: guest,
      started: true,
      ended: true,
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )

    get "/api/v2/teams/#{archived_team.id}/stats"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal archived_league.id, body['team']['league_id']
    assert_equal 1, body['recent_games'].length
  end

  test 'stats antwortet mit 404, wenn die Liga des Teams gelöscht wurde' do
    login(create(:user, :admin))
    orphan_league = create(:league, game_operation: @go)
    orphan_team = create(:team, league: orphan_league, club: @club)
    # league_id zeigt ins Leere – so entstanden die Teams, die vorher einen
    # 500er auslösten (siehe Helfer unten).
    delete_league_leaving_orphans(orphan_league)

    get "/api/v2/teams/#{orphan_team.id}/stats"

    assert_response :not_found
    assert_match(/Liga/, JSON.parse(response.body)['message'])
  end

  test 'matches antwortet mit 404, wenn die Liga des Teams gelöscht wurde' do
    login(create(:user, :admin))
    orphan_league = create(:league, game_operation: @go)
    orphan_team = create(:team, league: orphan_league, club: @club)
    delete_league_leaving_orphans(orphan_league)

    get "/api/v2/teams/#{orphan_team.id}/matches"

    assert_response :not_found
    refute JSON.parse(response.body)['success']
  end

  # Der 404 allein ist von „diese Mannschaft gibt es nicht" nicht zu
  # unterscheiden. Ein Team ohne auflösbare Liga ist aber ein kaputter
  # Datensatz und muss auffallen – vorher war der 500er das einzige Signal.
  test 'ein Team ohne auflösbare Liga wird gemeldet' do
    login(create(:user, :admin))
    orphan_league = create(:league, game_operation: @go)
    orphan_team = create(:team, league: orphan_league, club: @club)
    delete_league_leaving_orphans(orphan_league)
    Rails.cache.delete("orphan_team_reported/#{orphan_team.id}")

    messages = []
    Sentry.stub(:capture_message, ->(message, *) { messages << message }) do
      get "/api/v2/teams/#{orphan_team.id}/stats"
    end

    assert_response :not_found
    assert_equal 1, messages.size
    assert_includes messages.first, "team: #{orphan_team.id}"
  end

  # Die Sperre haengt an Rails.cache. Im Test-Env ist das ein :null_store, in
  # dem jedes write durchgeht – ohne echten Store wuerde der Test die Sperre
  # gar nicht pruefen, sondern nur bestaetigen, dass drei Aufrufe drei
  # Meldungen erzeugen.
  test 'die Meldung ueber ein Team ohne Liga wiederholt sich nicht je Aufruf' do
    login(create(:user, :admin))
    orphan_league = create(:league, game_operation: @go)
    orphan_team = create(:team, league: orphan_league, club: @club)
    delete_league_leaving_orphans(orphan_league)

    messages = []
    with_real_cache do
      Sentry.stub(:capture_message, ->(message, *) { messages << message }) do
        3.times { get "/api/v2/teams/#{orphan_team.id}/stats" }
      end
    end

    assert_equal 1, messages.size
  end

  # Eine Liga hart entfernen, obwohl noch eine Mannschaft auf sie zeigt. Genau
  # so sind die Datensätze entstanden, um die es in diesen Tests geht.
  #
  # Seit dem Fremdschlüssel aus #293 verweigert die Datenbank das, der muss für
  # den Altbestand hier also kurz weichen. Das DDL läuft in der Testtransaktion
  # und ist mit ihr wieder verschwunden. Dass der Weg heute versperrt ist, prüft
  # `CleanupOrphanTeamLeaguesTest`.
  def delete_league_leaving_orphans(league)
    ActiveRecord::Base.connection.remove_foreign_key(:teams, :leagues)
    League.where(id: league.id).delete_all
  end

  test 'stats nutzt die Pokal-Liga als Saisonquelle, wenn die Hauptliga fehlt' do
    login(create(:user, :admin))
    cup_league = create(:league, game_operation: @go)
    cup_team = create(:team, league: @league, club: @club, cup_leagues: [cup_league.id])
    cup_team.update_column(:league_id, nil)

    get "/api/v2/teams/#{cup_team.id}/stats"

    assert_response :success
    assert_equal cup_league.id, JSON.parse(response.body)['team']['league_id']
  end

  # cup_leagues wird beim Speichern nur gegen den Spielbetrieb geprüft, nie
  # gegen die Saison – ein Team kann dort Ligen aus mehreren Saisons stehen
  # haben. Genommen werden muss die jüngste.
  #
  # 17 und 18, weil `League` einen default_scope nach season_id hat: `.first`
  # nähme damit die lexikografisch kleinste, hier also die ältere Saison, und
  # die Mannschaftsseite zeigte den Stand von vorletztem Jahr.
  test 'stats nimmt bei mehreren Pokal-Ligen die juengste Saison' do
    login(create(:user, :admin))
    alt = create(:league, game_operation: @go, season_id: '17')
    neu = create(:league, game_operation: @go, season_id: '18')
    cup_team = create(:team, league: @league, club: @club, cup_leagues: [alt.id, neu.id])
    cup_team.update_column(:league_id, nil)

    get "/api/v2/teams/#{cup_team.id}/stats"

    assert_response :success
    assert_equal neu.id, JSON.parse(response.body)['team']['league_id']
  end

  # season_id ist eine Textspalte. Ein reiner Größtwert über Zeichenketten
  # stellte "9" hinter "10" und nähme damit die ältere Saison.
  test 'stats vergleicht die Saison numerisch, nicht als Zeichenkette' do
    login(create(:user, :admin))
    alt = create(:league, game_operation: @go, season_id: '9')
    neu = create(:league, game_operation: @go, season_id: '10')
    cup_team = create(:team, league: @league, club: @club, cup_leagues: [alt.id, neu.id])
    cup_team.update_column(:league_id, nil)

    get "/api/v2/teams/#{cup_team.id}/stats"

    assert_response :success
    assert_equal neu.id, JSON.parse(response.body)['team']['league_id']
  end

  # Beendetes Spiel des Teams in `league` mit genau einem Tor eines eigenen
  # Spielers; liefert diesen Spieler (ergibt einen Scorer-Eintrag über
  # Game#evaluate_scorer).
  def game_with_goal(team, league, trikot_number)
    guest = create(:team, league:, club: @club)
    player = create(:player)
    game_day = GameDay.create!(league:, arena: create(:arena), club: @club, number: 1, date: '2026-01-01')
    Game.create!(
      game_day:, home_team: team, guest_team: guest,
      started: true, ended: true, forfait: 0, overtime: false, legacy: false,
      events: [{ 'id' => 1, 'period' => 1, 'time' => '5:00', 'home_number' => trikot_number,
                 'home_goals' => 1, 'guest_goals' => 0 }],
      players: { 'home' => [{ 'trikot_number' => trikot_number, 'player_id' => player.id }], 'guest' => [] }
    )
    player
  end

  def team_with_scorer(enable_scorer:)
    league = create(:league, game_operation: @go, enable_scorer:)
    team = create(:team, league:, club: @club)
    game_with_goal(team, league, 7)
    team
  end

  test 'stats liefert die Scorerliste, wenn die Liga sie öffentlich zeigt' do
    login(create(:user, :admin))
    team = team_with_scorer(enable_scorer: true)

    get "/api/v2/teams/#{team.id}/stats"

    assert_response :success
    body = JSON.parse(response.body)
    assert body['scorer_visible']
    assert_equal 1, body['scorer'].length
    assert_equal 1, body['totals']['goals']
  end

  test 'stats liefert keine Scorerliste, wenn die Liga sie ausblendet' do
    login(create(:user, :admin))
    team = team_with_scorer(enable_scorer: false)

    get "/api/v2/teams/#{team.id}/stats"

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body['scorer_visible']
    assert_empty body['scorer']
    # Team-Summen bleiben erhalten, sie sind keine personenbezogene Rangliste.
    assert_equal 1, body['totals']['goals']
  end

  test 'stats behält die Scorerpunkte der Ligen, die ihre Scorerliste zeigen' do
    login(create(:user, :admin))
    # Typischer Fall: Hauptliga zeigt die Scorerliste, eine zusätzliche
    # Relegations-/Qualifikationsliga nicht (enable_scorer hat Default false).
    main_league = create(:league, game_operation: @go, enable_scorer: true)
    cup_league = create(:league, game_operation: @go, enable_scorer: false)
    team = create(:team, league: main_league, club: @club, cup_leagues: [cup_league.id])
    visible_player = game_with_goal(team, main_league, 7)
    game_with_goal(team, cup_league, 8)

    get "/api/v2/teams/#{team.id}/stats"

    assert_response :success
    body = JSON.parse(response.body)
    assert body['scorer_visible']
    scorer_player_ids = body['scorer'].map { |s| s['player_id'] }
    assert_equal [visible_player.id], scorer_player_ids
    # Die Summen zählen weiter alle Spiele des Teams, also beide Tore.
    assert_equal 2, body['totals']['goals']
  end

  # Nachweis, dass die Auswertung tatsächlich aus dem Cache kommt: Nach dem
  # ersten Aufruf bekommt das Team ein weiteres beendetes Spiel mit einem Tor.
  # Ohne Cache stünde danach eine 2 in den Summen. Dass die 1 bleibt, ist die
  # gewollte Unschärfe von 5 Minuten, dieselbe wie bei leagues/:id/scorer.
  #
  # Ohne echten Store liefe der Block von Rails.cache.fetch bei jedem Aufruf,
  # der Test würde also auch bei fehlendem Cache bestehen (siehe with_real_cache
  # in test_helper.rb).
  test 'stats liefert die Scorerwerte innerhalb der TTL aus dem Cache' do
    login(create(:user, :admin))
    team = team_with_scorer(enable_scorer: true)

    with_real_cache do
      get "/api/v2/teams/#{team.id}/stats"
      assert_response :success
      assert_equal 1, JSON.parse(response.body)['totals']['goals']

      game_with_goal(team, team.league, 8)

      get "/api/v2/teams/#{team.id}/stats"
      assert_response :success
      assert_equal 1, JSON.parse(response.body)['totals']['goals'],
                   'Die Werte wurden neu berechnet, der Cache greift nicht'
    end
  end

  # Gegenprobe zum Test darüber: Ohne Cache ist das zweite Spiel sofort da. So
  # bleibt belegt, dass die 1 oben am Cache liegt und nicht daran, dass der
  # Helfer kein zweites Tor anlegt.
  test 'stats zählt ein neues Spiel ohne Cache sofort mit' do
    login(create(:user, :admin))
    team = team_with_scorer(enable_scorer: true)

    get "/api/v2/teams/#{team.id}/stats"
    assert_equal 1, JSON.parse(response.body)['totals']['goals']

    game_with_goal(team, team.league, 8)

    get "/api/v2/teams/#{team.id}/stats"
    assert_equal 2, JSON.parse(response.body)['totals']['goals']
  end

  test 'stats liefert nach dem Umschalten von enable_scorer sofort die neue Sichtbarkeit' do
    login(create(:user, :admin))
    team = team_with_scorer(enable_scorer: true)

    with_real_cache do
      get "/api/v2/teams/#{team.id}/stats"
      assert_response :success
      assert JSON.parse(response.body)['scorer_visible']

      # Die sichtbaren Ligen stehen im Cache-Key. Ohne sie liefe die Maske bis
      # zum Ablauf der TTL weiter mit der alten Sichtbarkeit.
      team.league.update!(enable_scorer: false)

      get "/api/v2/teams/#{team.id}/stats"
      assert_response :success
      body = JSON.parse(response.body)
      assert_not body['scorer_visible']
      assert_empty body['scorer']
      # Die Team-Summen bleiben davon unberührt, sie zählen alle Ligen.
      assert_equal 1, body['totals']['goals']
    end
  end

  test 'stats trennt die gecachten Werte zweier Teams' do
    login(create(:user, :admin))
    team_a = team_with_scorer(enable_scorer: true)
    team_b = create(:team, league: create(:league, game_operation: @go, enable_scorer: true), club: @club)
    game_with_goal(team_b, team_b.league, 9)
    game_with_goal(team_b, team_b.league, 11)

    with_real_cache do
      get "/api/v2/teams/#{team_a.id}/stats"
      assert_equal 1, JSON.parse(response.body)['totals']['goals']

      get "/api/v2/teams/#{team_b.id}/stats"
      assert_equal 2, JSON.parse(response.body)['totals']['goals']
    end
  end

  test 'destroy lehnt Löschung mit 422 ab, wenn eine Spieltag-Bestätigung existiert (DB-FK)' do
    login(create(:user, :admin))
    arena = create(:arena)
    game_day = GameDay.create!(league: @league, arena:, club: @club, number: 1, date: '2026-01-01')
    GameDayTeamConfirmation.create!(game_day:, team: @team, confirmed_at: Time.current)

    delete "/api/v2/admin/teams/#{@team.id}"

    assert_response :unprocessable_entity
    assert_match(/verknüpfte Einträge/, JSON.parse(response.body)['message'])
    assert Team.exists?(@team.id)
  end

  test 'admin_upload_logo akzeptiert ein quadratisches PNG' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: square_png_upload(120) }

    assert_response :success
    assert @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt ein nicht-quadratisches Bild mit 422 ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: png_upload(200, 100, 'wide') }

    assert_response :unprocessable_entity
    assert_match(/quadratisch/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt ein unzulässiges Format mit 422 ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo",
         params: { logo: Rack::Test::UploadedFile.new(gif_path, 'image/gif') }

    assert_response :unprocessable_entity
    assert_match(/Dateiformat/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt SVG mit 422 ab (nur Raster-Formate erlaubt)' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo",
         params: { logo: Rack::Test::UploadedFile.new(svg_path, 'image/svg+xml') }

    assert_response :unprocessable_entity
    assert_match(/Dateiformat/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt eine zu große Datei mit 422 ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: oversized_png_upload }

    assert_response :unprocessable_entity
    assert_match(/zu groß/, JSON.parse(response.body)['message'])
    assert_not @team.reload.logo.attached?
  end

  test 'admin_upload_logo lehnt einen Nicht-Datei-Parameter mit 422 (statt 500) ab' do
    login(create(:user, :admin))

    post "/api/v2/admin/teams/#{@team.id}/upload_logo", params: { logo: 'kein-bild' }

    assert_response :unprocessable_entity
    assert_not @team.reload.logo.attached?
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def square_png_upload(size)
    png_upload(size, size, "square#{size}")
  end

  def png_upload(width, height, name)
    require 'vips'
    path = Rails.root.join('tmp', "logo_test_#{name}.png").to_s
    Vips::Image.black(width, height).pngsave(path)
    Rack::Test::UploadedFile.new(path, 'image/png')
  end

  def gif_path
    path = Rails.root.join('tmp', 'logo_test.gif').to_s
    # Kleinstmögliches GIF (nur der Header zählt, geprüft wird ausschließlich der content_type).
    File.binwrite(path, "GIF89a\x01\x00\x01\x00\x00\x00\x00;")
    path
  end

  def svg_path
    path = Rails.root.join('tmp', 'logo_test.svg').to_s
    File.write(path, '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"></svg>')
    path
  end

  def oversized_png_upload
    path = Rails.root.join('tmp', 'logo_test_big.png').to_s
    File.binwrite(path, "\x00" * (3.megabytes + 1))
    Rack::Test::UploadedFile.new(path, 'image/png')
  end
end
