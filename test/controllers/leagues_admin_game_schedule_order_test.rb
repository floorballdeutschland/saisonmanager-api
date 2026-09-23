require 'test_helper'

# GET /api/v2/admin/leagues/:id/game_schedule – Reihenfolge der Spieltage in der
# Spielplanverwaltung (#658). Die Spieltage werden jeweils in der verkehrten
# Reihenfolge angelegt, damit die Anlagereihenfolge das Ergebnis nicht zufällig
# richtig liefert.
class LeaguesAdminGameScheduleOrderTest < ActionDispatch::IntegrationTest
  setup do
    @go = GameOperation.create!(name: 'GO', short_name: 'GO')
    @league = League.create!(game_operation: @go, name: 'Turnierliga', season_id: '18',
                             table_modus: 'classic')
    @club = Club.create!(name: 'Testverein')
    @arena = Arena.create!(name: 'Halle A', city: 'Stadtstadt', active: true)
    @home = Team.create!(league: @league, club: @club, name: 'Heimteam')
    @guest = Team.create!(league: @league, club: @club, name: 'Gastteam')
    login
  end

  test 'gleiche Nummer und gleiches Datum ordnet die kleinste Spielnummer' do
    late = create_game_day(number: 1, date: '2026-04-06')
    create_game(late, '9')
    early = create_game_day(number: 1, date: '2026-04-06')
    create_game(early, '5')

    assert_equal [early.id, late.id], schedule_ids
  end

  test 'ein Spieltag ohne Spielnummer rutscht nicht nach vorne' do
    blank = create_game_day(number: 1, date: '2026-04-06')
    create_game(blank, '')
    numbered = create_game_day(number: 1, date: '2026-04-06')
    create_game(numbered, '3')

    assert_equal [numbered.id, blank.id], schedule_ids
  end

  test 'ein Datum in deutscher Schreibweise sortiert nach seinem echten Wert' do
    german = create_game_day(number: 1, date: '2026-08-11')
    create_game(german, '2')
    # Am Modell vorbei: Die ISO-Prüfung lässt die deutsche Schreibweise heute
    # nicht mehr durch, im Altbestand steht sie trotzdem.
    german.update_column(:date, '11.08.2026')
    iso = create_game_day(number: 1, date: '2026-04-06')
    create_game(iso, '1')

    assert_equal [iso.id, german.id], schedule_ids
  end

  # Ohne nummerierte Spiele ist der Spielnummer-Schlüssel bei allen gleich,
  # dann entscheidet die ID. Die Updates schreiben die Zeilen in Postgres in
  # umgekehrter Reihenfolge ans Ende der Tabelle, ohne ORDER BY kämen sie also
  # verkehrt herum.
  test 'Gleichstand ohne Spielnummern entscheidet die ID' do
    game_days = Array.new(5) { create_game_day(number: 1, date: '2026-04-06') }
    game_days.reverse_each { |game_day| game_day.update_column(:updated_at, 1.minute.from_now) }

    assert_equal game_days.map(&:id), schedule_ids
  end

  # Date.parse wirft bei mehr als 128 Zeichen ArgumentError, nicht Date::Error.
  test 'ein ueberlanger Datumstext fuehrt nicht zum Serverfehler' do
    odd = create_game_day(number: 1, date: '2026-04-06')
    odd.update_column(:date, 'x' * 200)
    create_game_day(number: 1, date: '2026-04-06')

    assert_equal 2, schedule_ids.length
  end

  private

  def schedule_ids
    get "/api/v2/admin/leagues/#{@league.id}/game_schedule"
    assert_response :success

    JSON.parse(response.body).map { |game_day| game_day['id'] }
  end

  def create_game_day(number:, date:)
    GameDay.create!(league: @league, arena: @arena, club: @club, number:, date:)
  end

  def create_game(game_day, game_number)
    Game.create!(game_day:, home_team: @home, guest_team: @guest, game_number:)
  end

  def login
    user = User.create!(user_name: "sortuser_#{SecureRandom.hex(4)}", password: 'password123',
                        password_confirmation: 'password123', teams: [],
                        permissions: [{ 'user_group_id' => 1, 'game_operation_id' => 0 }])
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
