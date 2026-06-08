require 'test_helper'

class PublicLicenseListControllerTest < ActionDispatch::IntegrationTest
  setup do
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
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest)
  end

  def token_for(game_id)
    Rails.application.message_verifier('license_list').generate(
      { game_id:, expires_at: 72.hours.from_now.iso8601 },
      expires_in: 72.hours
    )
  end

  test 'GET /public/license-list liefert valid_until je Lizenz mit aus' do
    player = create(:player, with_licenses: [{ team: @home, status: License::APPROVED }])
    player.licenses.first['valid_until'] = '2026-07-31'
    player.save!

    get '/api/v2/public/license_list', params: { token: token_for(@game.id) }

    assert_response :success
    entry = JSON.parse(response.body)['home_team_licenses'].first
    assert_equal '2026-07-31', entry['valid_until']
  end

  test 'GET /public/license-list mit ungültigem Token liefert 410' do
    get '/api/v2/public/license_list', params: { token: 'kaputt' }
    assert_response :gone
  end
end
