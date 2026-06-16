require 'test_helper'

# GET /api/v2/games/scheduling_conflicts – Hallen-Belegungskonflikte vor dem
# Speichern prüfen.
class GamesSchedulingConflictsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @go = GameOperation.create!(name: 'GO', short_name: 'GO')
    @league = League.create!(game_operation: @go, name: 'Liga', season_id: '18',
                             table_modus: 'classic', periods: 3, game_duration_minutes: 60)
    @club = Club.create!
    @arena = Arena.create!(name: 'Halle A', city: 'Stadt')
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-02-01')
    @home = Team.create!(league: @league, club: @club, name: 'H')
    @guest = Team.create!(league: @league, club: @club, name: 'G')
    @existing = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                             start_time: '14:00', forfait: 0, overtime: false, legacy: false,
                             events: [], players: { 'home' => [], 'guest' => [] })
  end

  test 'Admin erhält überschneidende Spiele als Konflikt' do
    login(create_user(user_group_id: 1, game_operation_id: 0))
    get '/api/v2/games/scheduling_conflicts',
        params: { game_day_id: @game_day.id, start_time: '14:30' }
    assert_response :success
    body = JSON.parse(response.body)
    conflict_ids = body['conflicts'].map { |c| c['id'] }
    assert_equal [@existing.id], conflict_ids
  end

  test 'kein Konflikt → leere Liste' do
    login(create_user(user_group_id: 1, game_operation_id: 0))
    get '/api/v2/games/scheduling_conflicts',
        params: { game_day_id: @game_day.id, start_time: '17:00' }
    assert_response :success
    assert_empty JSON.parse(response.body)['conflicts']
  end

  test 'Nutzer ohne Admin-/SBK-Rechte erhält 403' do
    login(create_user(user_group_id: 4, game_operation_id: 0)) # VM
    get '/api/v2/games/scheduling_conflicts',
        params: { game_day_id: @game_day.id, start_time: '14:30' }
    assert_response :forbidden
  end

  test 'unbekannter Spieltag → 404' do
    login(create_user(user_group_id: 1, game_operation_id: 0))
    get '/api/v2/games/scheduling_conflicts',
        params: { game_day_id: 0, start_time: '14:30' }
    assert_response :not_found
  end

  private

  def create_user(user_group_id:, game_operation_id:)
    User.create!(
      user_name: "authuser_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => user_group_id, 'game_operation_id' => game_operation_id }],
      teams: []
    )
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
