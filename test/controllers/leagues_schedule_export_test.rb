require 'test_helper'
require 'csv'

# GET /api/v2/admin/leagues/:id/schedule_export.(csv|xlsx) – Ausgabe des
# bestehenden Spielplans zur Weiterverarbeitung außerhalb des Saisonmanagers.
# Die Spaltenfolge ist dieselbe, die #admin_schedule_import_games liest; der
# erste Test hält das fest, weil die beiden Stellen sonst auseinanderlaufen,
# ohne dass es irgendwo auffällt.
class LeaguesScheduleExportTest < ActionDispatch::IntegrationTest
  setup do
    @go = GameOperation.create!(name: 'GO', short_name: 'GO')
    @league = League.create!(game_operation: @go, name: 'Testliga Nord', season_id: '18',
                             table_modus: 'classic')
    @club = Club.create!(name: 'Testverein')
    @arena = Arena.create!(name: 'Halle A', city: 'Stadtstadt', active: true)
    @home = Team.create!(league: @league, club: @club, name: 'Heimteam')
    @guest = Team.create!(league: @league, club: @club, name: 'Gastteam')
  end

  test 'Kopfzeile trägt die Spalten des Imports in derselben Reihenfolge' do
    login(admin_user)

    header = export_csv.first

    assert_equal template_header, header.first(LeaguesController::SCHEDULE_COLUMNS.length)
    assert_equal LeaguesController::SCHEDULE_EXPORT_COLUMNS,
                 header.last(LeaguesController::SCHEDULE_EXPORT_COLUMNS.length)
  end

  test 'jedes Spiel wird mit IDs und Klartext ausgegeben' do
    game_day = create_game_day(number: 1, date: '2026-04-06')
    game = create_game(game_day, game_number: '1', start_time: '19:00',
                                 nominated_referee_string: 'Mustermann/Müller',
                                 series_title: 'Halbfinale', series_number: '2')
    login(admin_user)

    row = export_csv[1]

    assert_equal ['1', '1', '1', '2026-04-06', '19:00', @arena.id.to_s, @club.id.to_s,
                  @home.id.to_s, @guest.id.to_s, 'Mustermann/Müller', 'Halbfinale', '2',
                  'Heimteam', 'Gastteam', 'Stadtstadt, Halle A', 'Testverein', game.id.to_s],
                 row
  end

  # Die Kopfzeile kommt aus den Konstanten, die Datenzeile aus
  # #schedule_export_row. Eine neue Spalte nur an einer der beiden Stellen
  # verschiebt ab da jeden Wert unter die falsche Überschrift.
  test 'Kopfzeile und Datenzeile haben gleich viele Spalten' do
    game_day = create_game_day(number: 1, date: '2026-04-06')
    create_game(game_day, game_number: '1')
    login(admin_user)

    rows = export_csv

    assert_equal rows[0].length, rows[1].length
  end

  test 'Spieltage und Spiele stehen in der Reihenfolge der Spielplanverwaltung' do
    # Absichtlich verkehrt herum angelegt: Sortiert wird nach Spieltagsnummer
    # und Spielnummer, nicht nach Anlagereihenfolge.
    second = create_game_day(number: 2, date: '2026-04-13')
    create_game(second, game_number: '3')
    first = create_game_day(number: 1, date: '2026-04-06')
    create_game(first, game_number: '2')
    create_game(first, game_number: '1')
    login(admin_user)

    rows = export_csv.drop(1)

    assert_equal(%w[1 2 3], rows.map { |r| r[1] })
    # Gruppierung: laufende Nummer je Spieltag, beide Spiele des ersten
    # Spieltags teilen sich also eine.
    assert_equal(%w[1 1 2], rows.map { |r| r[2] })
  end

  test 'ein Spieltag ohne Spiele erzeugt keine Zeile' do
    create_game_day(number: 1, date: '2026-04-06')
    login(admin_user)

    assert_equal 1, export_csv.length
  end

  test 'die Tabellenkalkulation bekommt ein echtes Datum, kein Text' do
    game_day = create_game_day(number: 1, date: '2026-04-06')
    create_game(game_day, game_number: '1')
    login(admin_user)

    get "/api/v2/admin/leagues/#{@league.id}/schedule_export.xlsx"
    assert_response :success

    file = Tempfile.new(['export', '.xlsx'])
    file.binmode
    file.write(response.body)
    file.flush

    sheets = Creek::Book.new(file.path, with_headers: false).sheets
    assert_equal %w[Spielplan Info Teams], sheets.map(&:name)

    rows = sheets[0].simple_rows.to_a
    assert_equal template_header, rows[0].values_at(*('A'..'L').to_a)
    # Creek liefert eine Datumszelle als Time, eine Textzelle als String. Der
    # Unterschied ist der Punkt der Spalte: Nur eine echte Datumszelle lässt
    # sich in der Tabellenkalkulation sortieren und rechnen.
    assert_kind_of Time, rows[1]['D']
    assert_equal Date.new(2026, 4, 6), rows[1]['D'].to_date
  ensure
    file&.close
  end

  test 'ohne Anmeldung kein Export' do
    get "/api/v2/admin/leagues/#{@league.id}/schedule_export.csv"

    assert_response :unauthorized
  end

  test 'ohne Verbandsrolle kein Export' do
    # Vereinsmanager: darf den Spielplan sehen, aber nicht als Datei ziehen –
    # dieselbe Grenze wie bei der Importvorlage.
    login(club_manager_user)

    get "/api/v2/admin/leagues/#{@league.id}/schedule_export.csv"

    assert_response :forbidden
  end

  test 'unbekannte Liga meldet 404 statt Serverfehler' do
    login(admin_user)

    get '/api/v2/admin/leagues/999999999/schedule_export.csv'

    assert_response :not_found
  end

  private

  # Die Überschriften des Import-Blattes, aus der Vorlage gelesen statt aus der
  # Konstante: Nur so hält der Test auch, wenn jemand die Vorlage von Hand
  # ändert, ohne den Export mitzunehmen.
  def template_header
    get "/api/v2/admin/leagues/#{@league.id}/schedule_import_template.xlsx"
    assert_response :success

    file = Tempfile.new(['template', '.xlsx'])
    file.binmode
    file.write(response.body)
    file.flush

    Creek::Book.new(file.path, with_headers: false).sheets[0].simple_rows.to_a[8]
               .values_at(*('A'..'L').to_a)
  ensure
    file&.close
  end

  def export_csv
    get "/api/v2/admin/leagues/#{@league.id}/schedule_export.csv"
    assert_response :success

    CSV.parse(response.body)
  end

  def create_game_day(number:, date:)
    GameDay.create!(league: @league, arena: @arena, club: @club, number:, date:)
  end

  def create_game(game_day, game_number:, **attributes)
    Game.create!(game_day:, home_team: @home, guest_team: @guest, game_number:, **attributes)
  end

  def admin_user
    create_user([{ 'user_group_id' => 1, 'game_operation_id' => 0 }])
  end

  def club_manager_user
    create_user([{ 'user_group_id' => 4, 'game_operation_id' => @go.id, 'club_id' => @club.id }])
  end

  def create_user(permissions)
    User.create!(
      user_name: "exportuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions:,
      teams: []
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
