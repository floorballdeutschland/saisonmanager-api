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

  test 'GET /public/license-list sortiert nach Nachnamen' do
    [%w[Anton Zander], %w[Xaver Abele], %w[Berta Mueller]].each do |first_name, last_name|
      create(:player, first_name:, last_name:,
                      with_licenses: [{ team: @home, status: License::APPROVED }])
    end

    get '/api/v2/public/license_list', params: { token: token_for(@game.id) }

    assert_response :success
    names = JSON.parse(response.body)['home_team_licenses'].map { |p| p['name'] }
    assert_equal ['Xaver Abele', 'Berta Mueller', 'Anton Zander'], names
  end

  # Ein Verlaufseintrag ohne `created_at` liess `max_by` platzen: „comparison of
  # NilClass with String failed", also eine 500 auf dem oeffentlichen Link kurz
  # vor Anwurf. Solche Eintraege gibt es im Altbestand.
  test 'GET /public/license-list uebersteht einen Verlaufseintrag ohne created_at' do
    player = create(:player, with_licenses: [{ team: @home, status: License::APPROVED }])
    player.licenses.first['history'] << { 'license_status_id' => License::APPROVED }
    player.save!

    get '/api/v2/public/license_list', params: { token: token_for(@game.id) }

    assert_response :success
    names = JSON.parse(response.body)['home_team_licenses'].map { |e| e['name'] }
    assert_includes names, "#{player.first_name} #{player.last_name}"
  end

  # Der Status liegt im JSONB mal als Zahl, mal als String vor. Ohne `to_i`
  # blieb „Genehmigt am" leer -- ausgerechnet die Spalte, an der am Kampfgericht
  # die Spielberechtigung abgelesen wird.
  test 'GET /public/license-list liest das Genehmigungsdatum auch bei Status als String' do
    player = create(:player, with_licenses: [{ team: @home, status: License::APPROVED }])
    player.licenses.first['history'].each do |h|
      h['license_status_id'] = h['license_status_id'].to_s
    end
    player.save!

    get '/api/v2/public/license_list', params: { token: token_for(@game.id) }

    assert_response :success
    entry = JSON.parse(response.body)['home_team_licenses'].first
    assert_not_nil entry['approved_at'], 'Genehmigungsdatum fehlt bei Status als String'
  end

  test 'GET /public/license-list mit ungültigem Token liefert 410' do
    get '/api/v2/public/license_list', params: { token: 'kaputt' }
    assert_response :gone
  end
end
