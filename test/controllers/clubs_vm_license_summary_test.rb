require 'test_helper'

# Lizenzzahlen eines Vereins je Mannschaft und Saison
# (GET vm/clubs/:id/license_summary).
class ClubsVmLicenseSummaryTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club, game_operation: @game_operation)
    @other_club = create(:club, game_operation: @game_operation)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @old_league = create(:league, :previous_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @old_team = create(:team, league: @old_league, club: @club)
    @foreign_team = create(:team, league: @league, club: @other_club)
    @vm = create(:user, :vm, club_id: @club.id)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def license(team, *status_ids)
    {
      'id' => SecureRandom.uuid, 'team_id' => team.id,
      'history' => status_ids.each_with_index.map do |status_id, i|
        { 'license_status_id' => status_id, 'created_at' => (10 - i).hours.ago.iso8601 }
      end
    }
  end

  def summary(params = {})
    login_as(@vm)
    get "/api/v2/vm/clubs/#{@club.id}/license_summary", params: params
    assert_response :success
    JSON.parse(response.body)
  end

  test 'zaehlt jede Lizenz der Mannschaft in genau einer Zahl' do
    create(:player, licenses: [license(@team, License::REQUESTED, License::APPROVED)])
    create(:player, licenses: [license(@team, License::REQUESTED)])
    create(:player, licenses: [license(@team, License::REQUESTED, License::DENIED)])
    create(:player, licenses: [license(@team, License::REQUESTED, License::WITHDRAWN)])
    # Erteilt und spaeter durch einen Transfer ungueltig: bleibt erteilt.
    create(:player, licenses: [license(@team, License::REQUESTED, License::APPROVED, License::TRANSFER)])
    create(:player, licenses: [license(@team, License::REQUESTED, License::DELETED)])

    row = summary['teams'].find { |t| t['id'] == @team.id }

    assert_equal({ 'approved' => 2, 'requested' => 1, 'denied' => 1, 'withdrawn' => 1, 'other' => 1, 'total' => 6 },
                 row['counts'])
  end

  test 'zeigt nur die Mannschaften der gewaehlten Saison und summiert sie' do
    create(:player, licenses: [license(@team, License::APPROVED), license(@old_team, License::APPROVED)])
    create(:player, licenses: [license(@old_team, License::APPROVED)])

    current = summary
    assert_equal 18, current['season_id']
    assert_equal([@team.id], current['teams'].map { |t| t['id'] })
    assert_equal 1, current['totals']['approved']

    previous = summary(season_id: 17)
    assert_equal([@old_team.id], previous['teams'].map { |t| t['id'] })
    assert_equal 2, previous['totals']['approved']
  end

  test 'nennt die Saisons, in denen der Verein Mannschaften hat' do
    assert_equal([18, 17], summary['seasons'].map { |s| s['id'] })
    assert_equal 'Saison 2024/25', summary['seasons'].last['name']
  end

  test 'laesst Lizenzen fremder Mannschaften weg' do
    create(:player, licenses: [license(@foreign_team, License::APPROVED)])

    assert_equal 0, summary['totals']['total']
  end

  test 'verweigert den VM eines anderen Vereins' do
    login_as(create(:user, :vm, club_id: @other_club.id))
    get "/api/v2/vm/clubs/#{@club.id}/license_summary"

    assert_response :forbidden
  end

  test 'zaehlt eine durch Spieler-Merge doppelte Lizenz einmal' do
    lic = license(@team, License::APPROVED)
    create(:player, licenses: [lic, lic.merge('season_id' => '18')])

    assert_equal 1, summary['totals']['approved']
  end

  test 'fuehrt Mannschaften, in denen der Verein SG-Partner ist' do
    partner_team = create(:team, league: @league, club: @other_club, syndicate: true,
                                 syndicate_clubs: [@club.id])
    create(:player, licenses: [license(partner_team, License::REQUESTED)])

    row = summary['teams'].find { |t| t['id'] == partner_team.id }

    assert_equal 1, row['counts']['requested']
  end

  test 'laesst Admin zu' do
    login_as(create(:user, :admin))
    get "/api/v2/vm/clubs/#{@club.id}/license_summary"

    assert_response :success
  end

  test 'verweigert den Teammanager ohne VM-Rolle' do
    login_as(create(:user, :tm, team_id: @team.id))
    get "/api/v2/vm/clubs/#{@club.id}/license_summary"

    assert_response :forbidden
  end

  test 'antwortet auf eine unbekannte Saison mit leerer Liste' do
    result = summary(season_id: 'abc')

    assert_equal [], result['teams']
    assert_equal 0, result['totals']['total']
  end

  # Das Frontend fragt die Uebersicht nur fuer Vereine mit diesem Flag an.
  test 'vm/clubs_and_teams sagt je Verein, ob die Uebersicht abrufbar ist' do
    # VM des eigenen Vereins und zugleich Teammanager einer fremden Mannschaft.
    user = create(:user, :vm, club_id: @club.id, teams: [@foreign_team.id])
    user.update!(permissions: user.permissions + [{ 'user_group_id' => 5, 'game_operation_id' => 0 }])
    login_as(user)
    get '/api/v2/vm/clubs_and_teams'
    assert_response :success

    flags = JSON.parse(response.body).to_h { |c| [c['id'], c['license_summary']] }

    assert flags[@club.id]
    assert_equal false, flags[@other_club.id]
  end
end
