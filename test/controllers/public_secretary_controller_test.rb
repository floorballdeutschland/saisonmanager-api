require 'test_helper'

class PublicSecretaryControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      user_name: "secretary_test_user_#{SecureRandom.hex(4)}",
      first_name: 'Max',
      last_name: 'Mustermann',
      password: 'password123'
    )
    @go = GameOperation.create!(name: 'Test GO', short_name: 'TGO')
    @league = League.create!(
      game_operation: @go,
      name: 'Testliga',
      season_id: '1',
      table_modus: 'classic'
    )
    @club = Club.create!
    @arena = Arena.create!(name: 'Testhalle', city: 'Teststadt')
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-01')
    @home = Team.create!(league: @league, club: @club, name: 'Heim')
    @guest = Team.create!(league: @league, club: @club, name: 'Gast')
    Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest)
  end

  test 'GET /public/secretary mit gültigem Token liefert 200 und created_by als fullname-String' do
    _link, raw_token = GameDaySecretaryLink.generate!(game_day: @game_day, created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'Max Mustermann', body['created_by'],
                 'created_by muss user.fullname sein (Regression: zuvor wurde user.name aufgerufen → NoMethodError → 500)'
    assert_equal @game_day.id, body.dig('game_day', 'id')
    assert_kind_of Array, body['games']
    assert_kind_of Hash, body['license_lists']
  end

  test 'GET /public/secretary ohne Token liefert 400' do
    get '/api/v2/public/secretary'
    assert_response :bad_request
    assert_equal 'Kein Token angegeben.', JSON.parse(response.body)['message']
  end

  test 'GET /public/secretary mit ungültigem Token liefert 410' do
    get '/api/v2/public/secretary', params: { token: 'nicht_existierender_token' }
    assert_response :gone
    assert_equal 'Dieser Link ist ungültig oder abgelaufen.', JSON.parse(response.body)['message']
  end

  test 'GET /public/secretary mit abgelaufenem Token liefert 410' do
    _link, raw_token = GameDaySecretaryLink.generate!(game_day: @game_day, created_by: @user)
    GameDaySecretaryLink.find_by(game_day: @game_day).update_column(:expires_at, 1.hour.ago)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :gone
  end
end
