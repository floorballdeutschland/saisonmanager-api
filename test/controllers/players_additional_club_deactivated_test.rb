require 'test_helper'

# api#513: `add_additional_club` prüfte nur Berechtigung und bestehende
# Mitgliedschaft, nicht den Zustand des Zielvereins. Ein deaktivierter Verein
# bekam so eine Zweitvereins-Mitgliedschaft, während die Direktzuweisung
# denselben Verein seit api#511 mit 422 abweist.
class PlayersAdditionalClubDeactivatedTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @go = create(:game_operation, state_association_id: create(:state_association).id)
    @home_club = create(:club, game_operation: @go)
    @player = create(:player, clubs: [{ 'club_id' => @home_club.id, 'home_club' => true }])
    @admin = create(:user, :admin)
  end

  test 'Zusatzverein in einem deaktivierten Verein wird abgewiesen' do
    target = create(:club, game_operation: @go, deactivated_at: Time.current)
    login_as(@admin)

    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: target.id }

    assert_response :unprocessable_entity
    assert_match(/deaktiviert/, JSON.parse(response.body)['message'])
    assert_equal [@home_club.id], @player.reload.clubs.map { |c| c['club_id'] },
                 'der abgewiesene Aufruf darf keine Mitgliedschaft anlegen'
  end

  # Gegenprobe: Die Regel gilt nur für den deaktivierten Verein, der reguläre
  # Zweitverein bleibt möglich.
  test 'Zusatzverein in einem aktiven Verein bleibt möglich' do
    target = create(:club, game_operation: @go)
    login_as(@admin)

    post "/api/v2/admin/players/#{@player.id}/add_additional_club", params: { club_id: target.id }

    assert_response :success
    assert_includes @player.reload.clubs.map { |c| c['club_id'] }, target.id
  end

  private

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end
end
