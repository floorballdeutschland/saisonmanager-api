require 'test_helper'

class RefereeHistoryControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @referee = create(:referee)
    @user = User.create!(
      user_name: "sr_hist_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: [],
      referee: @referee
    )

    go    = GameOperation.create!(name: 'GO Historie', short_name: 'GHI')
    club  = Club.create!
    arena = Arena.create!(name: 'Halle H', city: 'Stadt H')
    # leagues.season_id ist eine String-Spalte — genau daran scheiterte der
    # Namens-Lookup in der Integer-indizierten Setting.seasons-Map.
    league_new = League.create!(game_operation: go, season_id: '18', name: 'Liga Neu', table_modus: 'classic')
    league_old = League.create!(game_operation: go, season_id: '17', name: 'Liga Alt', table_modus: 'classic')
    day_new = GameDay.create!(league: league_new, arena: arena, club: club, number: 1, date: '2026-09-01')
    day_old = GameDay.create!(league: league_old, arena: arena, club: club, number: 1, date: '2025-09-01')
    [day_new, day_old].each do |day|
      Game.create!(game_day: day, officiating_referee_ids: [@referee.id],
                   events: [], players: { 'home' => [], 'guest' => [] },
                   forfait: 0, overtime: false, legacy: false)
    end
  end

  test 'games loest Saisonnamen aus Setting.seasons auf statt der rohen Saisonnummer' do
    login(@user)
    get '/api/v2/referee/history/games'
    assert_response :success
    body = JSON.parse(response.body)

    assert_equal(['Saison 2025/26', 'Saison 2024/25'], body.map { |s| s['season_name'] })
  end

  test 'games sortiert Saisons absteigend und liefert die Spiele jeder Saison' do
    login(@user)
    get '/api/v2/referee/history/games'
    assert_response :success
    body = JSON.parse(response.body)

    assert_equal([18, 17], body.map { |s| s['season_id'] })
    assert_equal([1, 1], body.map { |s| s['games'].size })
  end

  test 'games ohne verknuepftes Schiedsrichterprofil liefert 403' do
    user = User.create!(
      user_name: "ohne_sr_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: []
    )
    login(user)
    get '/api/v2/referee/history/games'
    assert_response :forbidden
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
