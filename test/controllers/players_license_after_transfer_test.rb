require 'test_helper'

# Neuer Lizenzantrag nach Transfer und Freigabe zurueck.
#
# Fall aus Prod (Spieler 1340): Lizenz fuer Verein B erteilt, dann Transfer von
# B nach A (die Lizenz wird „ungültig wg. Transfer"), dann Freigabe von A an B.
# Die Mitgliedschaft bei B war damit wieder da, beantragen konnte B trotzdem
# nicht: Die alte Lizenz hielt den Spieler aus der Auswahl `other_players`
# heraus, und einen Knopf „erneut beantragen" gibt es fuer diesen Status nicht.
class PlayersLicenseAfterTransferTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @home_club = create(:club)
    @club = create(:club)
    @league = create(:league, :current_season)
    @team = create(:team, league: @league, club: @club)
    @vm = create(:user, :vm, club_id: @club.id)
    @player = create(:player, clubs: [
      { 'club_id' => @home_club.id, 'home_club' => true, 'created_at' => 2.days.ago.iso8601 },
      { 'club_id' => @club.id, 'home_club' => false, 'created_at' => 2.days.ago.iso8601,
        'valid_until' => 1.year.from_now.iso8601 }
    ])
    @player.update!(licenses: [transfer_license])
  end

  def transfer_license
    {
      'id' => Digest::UUID.uuid_v4, 'team_id' => @team.id,
      'season_id' => @league.season_id, 'league_class_id' => @league.league_class_id,
      'history' => [
        { 'license_status_id' => License::REQUESTED, 'created_at' => 5.days.ago.iso8601 },
        { 'license_status_id' => License::APPROVED, 'created_at' => 4.days.ago.iso8601 },
        { 'license_status_id' => License::TRANSFER, 'created_at' => 2.days.ago.iso8601, 'reason' => 'Transfer' }
      ]
    }
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def team_licenses
    get "/api/v2/user/team/#{@team.id}/licenses"
    assert_response :success
    JSON.parse(response.body)
  end

  test 'Spieler mit Transferlizenz steht in der Auswahl fuer einen neuen Antrag' do
    login_as(@vm)
    body = team_licenses

    assert(body['other_players'].any? { |p| p['id'] == @player.id },
           'der zurueckgekehrte Spieler muss neu beantragt werden koennen')
    assert_not(body['current_requests'].any? { |p| p['id'] == @player.id })
  end

  test 'neuer Antrag geht durch und ersetzt in der Maske die Transferlizenz' do
    login_as(@vm)
    post "/api/v2/user/players/#{@player.id}/request_license", params: { team_id: @team.id }, as: :json
    assert_response :success
    assert_equal 2, @player.reload.licenses.size

    body = team_licenses
    item = body['current_requests'].find { |p| p['id'] == @player.id }
    assert item, 'der neue Antrag muss in der Liste stehen'
    assert_equal License::REQUESTED, item['current_status']['license_status_id']
    assert_not(body['other_players'].any? { |p| p['id'] == @player.id })
  end
end
