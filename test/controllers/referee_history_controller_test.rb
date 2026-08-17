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

    go    = GameOperation.create!(name: 'GO Historie', short_name: 'GHI', path: 'ghi')
    club  = Club.create!
    arena = Arena.create!(name: 'Halle H', city: 'Stadt H')
    # leagues.season_id ist eine String-Spalte — genau daran scheiterte der
    # Namens-Lookup in der Integer-indizierten Setting.seasons-Map.
    @league_new = League.create!(game_operation: go, season_id: '18', name: 'Liga Neu', table_modus: 'classic')
    @league_old = League.create!(game_operation: go, season_id: '17', name: 'Liga Alt', table_modus: 'classic')
    day_new = GameDay.create!(league: @league_new, arena: arena, club: club, number: 1, date: '2026-09-01')
    day_old = GameDay.create!(league: @league_old, arena: arena, club: club, number: 1, date: '2025-09-01')
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

  test 'games liefert je Spiel Liga-ID und Verband-Slug fuer den Link zur Spielseite' do
    login(@user)
    get '/api/v2/referee/history/games'
    assert_response :success
    body = JSON.parse(response.body)

    games = body.to_h { |s| [s['season_id'], s['games'].first] }
    assert_equal @league_new.id, games[18]['league_id']
    assert_equal @league_old.id, games[17]['league_id']
    assert_equal(%w[ghi ghi], games.values.map { |g| g['game_operation_slug'] })
  end

  test 'partners liefert die eigene Gespann-Historie' do
    partner = create(:referee)
    league = create(:league, season_id: '18')
    create(:game,
           game_day: create(:game_day, league: league),
           officiating_referee_ids: [@referee.id, partner.id])
    login(@user)

    get '/api/v2/referee/history/partners'

    assert_response :success
    body = response.parsed_body
    assert_equal @referee.id, body['referee']['id']
    assert_equal([partner.id], body['partners'].map { |p| p['referee_id'] })
    assert_equal 1, body['partners'].first['games_current_season']
    assert body['notice'].present?, 'Hinweis zur Belastbarkeit der Altdaten fehlt'
  end

  test 'partners ohne verknuepftes Schiedsrichterprofil liefert 403' do
    user = User.create!(
      user_name: "ohne_sr_p_#{SecureRandom.hex(4)}",
      password: 'password123',
      password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: []
    )
    login(user)

    get '/api/v2/referee/history/partners'

    assert_response :forbidden
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
