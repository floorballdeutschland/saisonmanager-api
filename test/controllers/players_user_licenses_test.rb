require 'test_helper'

# GET user/leagues/:id/licenses ist die Lizenzliste einer Liga fuer Vereine und
# Teams. Sie zeigt auch die Kader der Gegner und darf deshalb nur liefern, was
# die Liste anzeigt, nicht den Player#full_hash der Spielerverwaltung.
class PlayersUserLicensesTest < ActionDispatch::IntegrationTest
  ALLOWED_PLAYER_KEYS = %w[id first_name last_name adult_on team_license].freeze

  setup do
    create(:setting)
    @league = create(:league, :current_season, game_operation: create(:game_operation))
    @own_club = create(:club)
    @other_club = create(:club)
    @own_team = create(:team, league: @league, club: @own_club)
    @other_team = create(:team, league: @league, club: @other_club)

    @adult = create(:player, birthdate: '1990-05-01', email: 'erwachsen@example.org',
                             security_id: 'SEC-1', deactivation_reason: 'intern',
                             public_last_name_hidden_reason: 'Schutzgrund',
                             clubs: [{ 'club_id' => @other_club.id, 'home_club' => true }],
                             with_licenses: [{ team: @other_team, gf_role: 'erstlizenz' }])
    @minor = create(:player, birthdate: '2010-03-15', email: 'kind@example.org',
                             with_licenses: [{ team: @other_team, status: License::REQUESTED }])

    @vm = create(:user, :vm, club_id: @own_club.id)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def players_of(body, team)
    body.find { |t| t['id'] == team.id }['players']
  end

  test 'VM sieht fremde Kader nur mit den Feldern der Lizenzliste' do
    travel_to Time.zone.parse('2026-11-13 12:00') do
      login_as(@vm)
      get "/api/v2/user/leagues/#{@league.id}/licenses.json"
    end
    assert_response :success

    players = players_of(JSON.parse(response.body), @other_team)
    assert_equal 2, players.size
    players.each do |p|
      assert_empty p.keys - ALLOWED_PLAYER_KEYS, "unerwartete Felder: #{p.keys - ALLOWED_PLAYER_KEYS}"
      assert_empty p['team_license'].keys - %w[license last_status_id last_status_code
                                               approved_at requested_at released_at suspension]
      assert_equal ['gf_role'], p['team_license']['license'].keys
    end

    body = response.body
    %w[erwachsen@example.org kind@example.org 1990-05-01 2010-03-15 SEC-1 Schutzgrund intern].each do |secret|
      assert_not_includes body, secret
    end
  end

  test 'adult_on nur fuer Minderjaehrige, Status und Rolle bleiben erhalten' do
    travel_to Time.zone.parse('2026-11-13 12:00') do
      login_as(@vm)
      get "/api/v2/user/leagues/#{@league.id}/licenses.json"
    end

    by_id = players_of(JSON.parse(response.body), @other_team).index_by { |p| p['id'] }
    adult = by_id.fetch(@adult.id)
    minor = by_id.fetch(@minor.id)

    assert_nil adult['adult_on']
    assert_equal '2028-03-15', minor['adult_on']
    assert_equal 'erstlizenz', adult['team_license']['license']['gf_role']
    assert_equal License::APPROVED, adult['team_license']['last_status_id']
    assert_equal License::REQUESTED, minor['team_license']['last_status_id']
    assert_equal @adult.last_name, adult['last_name']
  end

  test 'am 29.02. Geborene sind wie im Frontend erst ab dem 01.03. volljaehrig' do
    @minor.update!(birthdate: '2012-02-29')
    travel_to Time.zone.parse('2026-11-13 12:00') do
      login_as(@vm)
      get "/api/v2/user/leagues/#{@league.id}/licenses.json"
    end

    minor = players_of(JSON.parse(response.body), @other_team).find { |p| p['id'] == @minor.id }
    assert_equal '2030-03-01', minor['adult_on']
  end

  test 'eigene Mannschaft bekommt dieselbe Feldliste' do
    create(:player, email: 'eigen@example.org', with_licenses: [{ team: @own_team }])
    login_as(@vm)
    get "/api/v2/user/leagues/#{@league.id}/licenses.json"

    players = JSON.parse(response.body).flat_map { |t| t['players'] }
    assert_equal 3, players.size
    players.each { |p| assert_empty p.keys - ALLOWED_PLAYER_KEYS }
    assert_not_includes response.body, 'eigen@example.org'
  end

  test 'TM eines Teams der Liga sieht die Liste, ebenfalls gekuerzt' do
    login_as(create(:user, :tm, team_id: @own_team.id))
    get "/api/v2/user/leagues/#{@league.id}/licenses.json"

    assert_response :success
    players_of(JSON.parse(response.body), @other_team).each { |p| assert_empty p.keys - ALLOWED_PLAYER_KEYS }
    assert_not_includes response.body, 'erwachsen@example.org'
  end

  test 'Sperre zeigt Geltungsbereich und Spiele, aber keine Begruendung' do
    @adult.suspend!(user_id: create(:user).id, team_id: @other_team.id, games_total: 3,
                    reason: 'Taetlichkeit gegen SR XY')
    login_as(@vm)
    get "/api/v2/user/leagues/#{@league.id}/licenses.json"

    row = players_of(JSON.parse(response.body), @other_team).find { |p| p['id'] == @adult.id }
    suspension = row['team_license']['suspension']
    assert_equal %w[games_total remaining_games scope_summary valid_until], suspension.keys.sort
    assert_equal 3, suspension['games_total']
    assert_equal 3, suspension['remaining_games']
    assert_predicate suspension['scope_summary'], :present?
    assert_equal License::SUSPENDED, row['team_license']['last_status_id']
    assert_not_includes response.body, 'Taetlichkeit'
  end

  test 'ohne Geburtsdatum kein adult_on und kein Fehler' do
    @minor.update_column(:birthdate, nil)
    login_as(@vm)
    get "/api/v2/user/leagues/#{@league.id}/licenses.json"

    assert_response :success
    assert_nil players_of(JSON.parse(response.body), @other_team).find { |p| p['id'] == @minor.id }['adult_on']
  end

  test 'adult_on reicht ein Jahr zurueck, fuer vergangene Spieltage' do
    # 18 geworden am 10.11.2026, drei Tage vor heute: noch mit Datum.
    @minor.update!(birthdate: '2008-11-10')
    # 18 geworden am 12.11.2025, ein Jahr und einen Tag vor heute: ohne.
    @adult.update!(birthdate: '2007-11-12')
    travel_to Time.zone.parse('2026-11-13 12:00') do
      login_as(@vm)
      get "/api/v2/user/leagues/#{@league.id}/licenses.json"
    end

    by_id = players_of(JSON.parse(response.body), @other_team).index_by { |p| p['id'] }
    assert_equal '2026-11-10', by_id.fetch(@minor.id)['adult_on']
    assert_nil by_id.fetch(@adult.id)['adult_on']
  end

  test 'heute zaehlt in Berliner Zeit' do
    # 18. Geburtstag am 13.11.2025; 23:30 UTC am 12.11.2026 ist in Berlin schon
    # der 13.11., der Geburtstag liegt damit genau ein Jahr zurueck: ohne Datum.
    @minor.update!(birthdate: '2007-11-13')
    travel_to Time.utc(2026, 11, 12, 23, 30) do
      login_as(@vm)
      get "/api/v2/user/leagues/#{@league.id}/licenses.json"
    end

    assert_nil players_of(JSON.parse(response.body), @other_team).find { |p| p['id'] == @minor.id }['adult_on']
  end

  test 'ohne Beteiligung an der Liga bleibt es bei 403' do
    login_as(create(:user, :vm, club_id: create(:club).id))
    get "/api/v2/user/leagues/#{@league.id}/licenses.json"
    assert_response :forbidden
  end
end
