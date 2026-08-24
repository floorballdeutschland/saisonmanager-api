require 'test_helper'

# Wer Spieler*innen anlegen darf, entscheidet Club#user_permissions
# (:create_player). Teammanager*innen hatten das Recht bis 1.95.0 ebenfalls;
# seither legt nur der Vereinsmanager des Vereins an. Der Endpunkt ist die
# eigentliche Grenze -- die Vereinssicht blendet den Knopf nur ab.
class PlayersCreateRoleTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @club = create(:club)
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def anlegen(club_id)
    post '/api/v2/admin/players.json',
         params: { club_id:, first_name: 'Neu', last_name: 'Zugang',
                   birthdate: '2000-01-01', gender: 'M', nation_id: 1 },
         as: :json
  end

  test 'Teammanager darf im Verein der eigenen Mannschaft nicht anlegen' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))

    assert_no_difference 'Player.count' do
      anlegen(@club.id)
    end

    assert_response :forbidden
    assert_match 'Vereinsmanager', JSON.parse(response.body)['message']
  end

  # Die Spielgemeinschaft war der Fall, in dem der TM früher weiter reichte als
  # der VM: über Team#all_club_ids auch in die übrigen beteiligten Vereine.
  test 'Teammanager einer Spielgemeinschaft darf im beteiligten Verein nicht anlegen' do
    partner = create(:club)
    team = create(:team, club: @club, league: create(:league, :current_season),
                         syndicate: true, syndicate_clubs: [partner.id])
    login_as(create(:user, :tm, team_id: team.id))

    assert_no_difference 'Player.count' do
      anlegen(partner.id)
    end

    assert_response :forbidden
  end

  test 'Vereinsmanager legt im eigenen Verein weiter an' do
    login_as(create(:user, :vm, club_id: @club.id))

    assert_difference 'Player.count', 1 do
      anlegen(@club.id)
    end

    assert_response :created
    assert_equal @club.id, Player.last.clubs.first['club_id']
  end
end
