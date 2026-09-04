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
    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 'Max Mustermann', body['created_by'],
                 'created_by muss user.fullname sein (Regression: zuvor wurde user.name aufgerufen → NoMethodError → 500)'
    assert_equal @game_day.id, body.dig('game_day', 'id')
    assert_kind_of Array, body['games']
    assert_kind_of Hash, body['license_lists']
  end

  test 'GET /public/secretary liefert league_id und Verbands-Slug für den Link zur Spielseite' do
    # Kurzname mit Punkt und Leerzeichen: nur so ist der Test trennscharf,
    # denn slug ("1-fbl") weicht hier von short_name.downcase ("1. fbl") ab.
    @go.update!(short_name: '1. FBL', path: nil)
    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    game_day = JSON.parse(response.body)['game_day']
    assert_equal @league.id, game_day['league_id']
    assert_equal '1-fbl', game_day['game_operation_slug']
  end

  test 'GET /public/secretary liefert valid_until je Lizenz mit aus' do
    player = create(:player, with_licenses: [{ team: @home, status: License::APPROVED }])
    player.licenses.first['valid_until'] = '2026-07-31'
    player.save!

    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    entry = JSON.parse(response.body).dig('license_lists', @home.id.to_s, 'players').first
    assert_equal '2026-07-31', entry['valid_until']
  end

  test 'GET /public/secretary sortiert die Lizenzliste nach Nachnamen' do
    %w[Zander Abele Mueller].each_with_index do |last_name, i|
      create(:player, first_name: %w[Anton Xaver Berta][i], last_name:,
                      with_licenses: [{ team: @home, status: License::APPROVED }])
    end
    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    names = JSON.parse(response.body).dig('license_lists', @home.id.to_s, 'players').map { |p| p['name'] }
    assert_equal ['Xaver Abele', 'Berta Mueller', 'Anton Zander'], names
  end

  test 'GET /public/secretary sortiert Umlaute nicht ans Ende' do
    [%w[Anna Ötztaler], %w[Bea Zander], %w[Cem Ahrens]].each do |first_name, last_name|
      create(:player, first_name:, last_name:,
                      with_licenses: [{ team: @home, status: License::APPROVED }])
    end
    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    names = JSON.parse(response.body).dig('license_lists', @home.id.to_s, 'players').map { |p| p['name'] }
    assert_equal ['Cem Ahrens', 'Anna Ötztaler', 'Bea Zander'], names
  end

  test 'GET /public/secretary nennt je Lizenzliste die Liga des Spieltags' do
    other_league = League.create!(game_operation: @go, name: 'U13', season_id: '1', table_modus: 'classic')
    other_day = GameDay.create!(league: other_league, arena: @arena, club: @club, number: 1,
                                date: '2026-01-01')
    u13_home = Team.create!(league: other_league, club: @club, name: 'U13 Heim')
    u13_guest = Team.create!(league: other_league, club: @club, name: 'U13 Gast')
    Game.create!(game_day: other_day, home_team: u13_home, guest_team: u13_guest)

    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day, other_day], created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    lists = JSON.parse(response.body)['license_lists']
    assert_equal 'Testliga', lists[@home.id.to_s]['league_name']
    assert_equal @league.id, lists[@home.id.to_s]['league_id']
    assert_equal 'U13', lists[u13_home.id.to_s]['league_name']
    assert_equal other_league.id, lists[u13_home.id.to_s]['league_id']
  end

  test 'GET /public/secretary nennt die Liga des Spieltags, nicht die Stammliga der Mannschaft' do
    # Pokalspiel in derselben Halle: Die Mannschaft ist in der Testliga
    # beheimatet, tritt hier aber im Pokal an.
    cup = League.create!(game_operation: @go, name: 'Pokal', season_id: '1', table_modus: 'classic')
    cup_day = GameDay.create!(league: cup, arena: @arena, club: @club, number: 1, date: '2026-01-02')
    Game.create!(game_day: cup_day, home_team: @home, guest_team: @guest)

    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [cup_day], created_by: @user)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :success
    assert_equal @league.id, @home.league_id
    assert_equal 'Pokal', JSON.parse(response.body).dig('license_lists', @home.id.to_s, 'league_name')
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
    _link, raw_token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)
    GameDaySecretaryLink.covering([@game_day.id]).first.update_column(:expires_at, 1.hour.ago)

    get '/api/v2/public/secretary', params: { token: raw_token }

    assert_response :gone
  end
end
