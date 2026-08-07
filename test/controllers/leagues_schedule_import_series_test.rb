require 'test_helper'

# POST /api/v2/admin/leagues/import_schedule – Serien-Titel und Nummer in Serie
# (Spalten K und L der Import-Vorlage). Vor Issue #219 gab es die beiden
# Spalten in der Vorlage nicht, weshalb Playoff-Ligen in schedule.json
# durchgängig series_title = null lieferten.
class LeaguesScheduleImportSeriesTest < ActionDispatch::IntegrationTest
  XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'.freeze

  setup do
    @go = GameOperation.create!(name: 'GO', short_name: 'GO')
    @league = League.create!(game_operation: @go, name: 'Playoffs', season_id: '18',
                             table_modus: 'classic')
    @club = Club.create!(name: 'Testverein')
    @arena = Arena.create!(name: 'Halle A', city: 'Stadt', active: true)
    @home = Team.create!(league: @league, club: @club, name: 'H')
    @guest = Team.create!(league: @league, club: @club, name: 'G')

    login(admin_user)
  end

  test 'Serien-Titel und Nummer werden aus den Spalten K/L übernommen' do
    rows = [
      row(game_day: 1, game_number: 1, group: 1, series_title: 'Halbfinale', series_number: '1'),
      row(game_day: 1, game_number: 2, group: 2, series_title: 'Halbfinale', series_number: '2'),
      row(game_day: 2, game_number: 3, group: 3, series_title: 'Finale')
    ]
    import!(rows)

    assert_response :success

    games = imported_games
    assert_equal 3, games.size
    assert_equal %w[Halbfinale Halbfinale Finale], games.map(&:series_title)
    assert_equal ['1', '2', nil], games.map(&:series_number)
  end

  test 'leere Spalten K/L bleiben nil statt Leerstring' do
    import!([row(game_day: 1, game_number: 1, group: 1)])

    assert_response :success

    game = imported_games.first
    assert_nil game.series_title
    assert_nil game.series_number
  end

  test 'numerische Zelle in Spalte L wird nicht zu "1.0"' do
    # Excel speichert eine eingetippte 1 als Zahl; Creek liefert sie als Float.
    import!([row(game_day: 1, game_number: 1, group: 1, series_title: 'Viertelfinale', series_number: 1)])

    assert_response :success
    assert_equal '1', imported_games.first.series_number
  end

  test 'Serien-Titel landet in schedule.json' do
    import!([row(game_day: 1, game_number: 1, group: 1, series_title: 'Finale')])
    assert_response :success

    get "/api/v2/leagues/#{@league.id}/schedule"
    assert_response :success

    entry = JSON.parse(response.body).first
    assert_equal 'Finale', entry['series_title']
  end

  test 'Import-Vorlage führt Serien-Spalten als K und L' do
    get "/api/v2/admin/leagues/#{@league.id}/schedule_import_template.xlsx"
    assert_response :success

    file = Tempfile.new(['template', '.xlsx'])
    file.binmode
    file.write(response.body)
    file.flush

    header = Creek::Book.new(file.path, with_headers: false).sheets[0].simple_rows.to_a[8]

    assert_equal 'angesetzte Schiris', header['J']
    assert_equal 'Serien-Titel', header['K']
    assert_equal 'Nummer in Serie', header['L']
  ensure
    file&.close
  end

  private

  def imported_games
    Game.where(game_day_id: @league.game_days.select(:id)).order(:game_number)
  end

  def row(game_day:, game_number:, group:, series_title: nil, series_number: nil)
    [game_day, game_number, group, '2026-04-06', '19:00', @arena.id, @club.id,
     @home.id, @guest.id, '', series_title, series_number]
  end

  # Baut eine Datei im Format der Import-Vorlage: Blattname "Import",
  # Liga-ID in A2, ab Zeile 10 die Spiele.
  def import!(rows)
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: 'Import') do |sheet|
      sheet.add_row ['Importtabelle']
      sheet.add_row [@league.id]
      6.times { sheet.add_row [''] }
      sheet.add_row ['Spieltagsnummer', 'Spielnummer', 'Gruppierung', 'Datum', 'Anpfiff',
                     'ID der Halle', 'ID des Ausrichtenden Vereins', 'ID des Heimteams',
                     'ID des Gastteams', 'angesetzte Schiris', 'Serien-Titel', 'Nummer in Serie']
      rows.each { |r| sheet.add_row r }
    end

    file = Tempfile.new(['import', '.xlsx'])
    file.binmode
    file.write(package.to_stream.read)
    file.flush

    post '/api/v2/admin/leagues/import_schedule',
         params: { file: Rack::Test::UploadedFile.new(file.path, XLSX_MIME) }
  ensure
    file&.close
  end

  def admin_user
    User.create!(
      user_name: "importadmin_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }],
      teams: []
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
