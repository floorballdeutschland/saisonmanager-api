require 'test_helper'

# Anlegen, Deaktivieren und Reaktivieren sind Vereinsentscheidungen: Das
# Anlegen schreibt eine Heimatmitgliedschaft, die Deaktivierung nimmt das
# Profil aus der Spielerliste des Vereins und aus der Auswahl beim
# Lizenzantrag. Teammanager*innen hatten beides bis api#530; seither
# entscheidet der Vereinsmanager des Vereins. Die Endpunkte sind die
# eigentliche Grenze -- die Vereinssicht blendet die Knöpfe nur aus.
class PlayersClubDecisionsRoleTest < ActionDispatch::IntegrationTest
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

  # --- Deaktivieren und Reaktivieren -------------------------------------------

  def spieler_im_verein(deactivated_at: nil)
    create(:player,
           clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                     'created_at' => 1.year.ago.iso8601 }],
           deactivated_at:)
  end

  test 'Teammanager deaktiviert im Verein der eigenen Mannschaft nicht' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))
    spieler = spieler_im_verein

    post "/api/v2/admin/players/#{spieler.id}/deactivate", params: { reason: 'Karriereende' }

    assert_response :forbidden
    assert_match 'Vereinsmanager', JSON.parse(response.body)['message']
    assert_nil spieler.reload.deactivated_at
  end

  test 'Teammanager reaktiviert nicht' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))
    spieler = spieler_im_verein(deactivated_at: 1.day.ago)

    post "/api/v2/admin/players/#{spieler.id}/reactivate"

    assert_response :forbidden
    assert spieler.reload.deactivated_at.present?
  end

  # Das Profil selbst bleibt ihm offen: Aus diesem Bestand stellt er auf.
  test 'Teammanager sieht das Profil weiterhin' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))
    spieler = spieler_im_verein

    get "/api/v2/admin/players/#{spieler.id}.json"

    assert_response :success
  end

  # Die Spielgemeinschaft ist hier der schwerere Fall: Über `tm_club_ids`
  # (Team#all_club_ids) reichte der TM auch an Personen des Partnervereins,
  # konnte also den Bestand eines fremden Vereins ordnen.
  test 'Teammanager einer Spielgemeinschaft deaktiviert im Partnerverein nicht' do
    partner = create(:club)
    team = create(:team, club: @club, league: create(:league, :current_season),
                         syndicate: true, syndicate_clubs: [partner.id])
    login_as(create(:user, :tm, team_id: team.id))
    spieler = create(:player, clubs: [{ 'club_id' => partner.id, 'home_club' => true,
                                        'created_at' => 1.year.ago.iso8601 }])

    post "/api/v2/admin/players/#{spieler.id}/deactivate", params: { reason: 'Karriereende' }

    assert_response :forbidden
    assert_nil spieler.reload.deactivated_at
  end

  # Die E-Mail-Adresse bleibt beim Teammanager (`update_player_email` und
  # `can_manage_player?` sind bewusst nicht mitgewandert): Er erreicht die
  # Person über den Kader und trägt die Adresse für die Mannschaft nach.
  test 'Teammanager pflegt weiter die E-Mail-Adresse' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))
    spieler = spieler_im_verein

    patch "/api/v2/admin/vm/players/#{spieler.id}/email", params: { email: 'neu@example.org' }

    assert_response :success
    assert_equal 'neu@example.org', spieler.reload.email
  end

  # Mehrfachrollen: Beide Rollen gelten nebeneinander, jede in ihrem Verein.
  # Hier hängt außerdem die Meldung dran -- sie wird vereinsbezogen gewählt,
  # nicht über die Rollen des Kontos, sonst bekäme genau dieses Konto die
  # nichtssagende Absage.
  test 'wer VM des einen und TM im anderen Verein ist, legt nur im eigenen an' do
    vm_club = create(:club)
    tm_team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, teams: [tm_team.id], permissions: [
      { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => vm_club.id },
      { 'user_group_id' => 5, 'game_operation_id' => 0 }
    ]))

    assert_no_difference 'Player.count' do
      anlegen(@club.id)
    end
    assert_response :forbidden
    assert_match 'Vereinsmanager', JSON.parse(response.body)['message']

    assert_difference 'Player.count', 1 do
      anlegen(vm_club.id)
    end
    assert_response :created
  end

  test 'wer VM des einen und TM im anderen Verein ist, deaktiviert nur im eigenen' do
    vm_club = create(:club)
    tm_team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, teams: [tm_team.id], permissions: [
      { 'user_group_id' => 4, 'game_operation_id' => 0, 'club_id' => vm_club.id },
      { 'user_group_id' => 5, 'game_operation_id' => 0 }
    ]))
    fremd = spieler_im_verein
    eigen = create(:player, clubs: [{ 'club_id' => vm_club.id, 'home_club' => true,
                                      'created_at' => 1.year.ago.iso8601 }])

    post "/api/v2/admin/players/#{fremd.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :forbidden
    assert_match 'Vereinsmanager', JSON.parse(response.body)['message']
    assert_nil fremd.reload.deactivated_at

    post "/api/v2/admin/players/#{eigen.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :success
  end

  # Eine mitgeschickte, aber unlesbare id gilt als Anlage (to_i == 0). Gemeint
  # war eine Änderung, der Rollenhinweis wäre also eine falsche Fährte.
  test 'unlesbare id bekommt die neutrale Absage, nicht den Rollenhinweis' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))

    post '/api/v2/admin/players.json',
         params: { id: 'abc', club_id: @club.id, first_name: 'Neu', last_name: 'Zugang',
                   birthdate: '2000-01-01', gender: 'M', nation_id: 1 },
         as: :json

    assert_response :forbidden
    assert_no_match(/Vereinsmanager/, JSON.parse(response.body)['message'])
  end

  test 'Vereinsmanager deaktiviert und reaktiviert weiter' do
    login_as(create(:user, :vm, club_id: @club.id))
    spieler = spieler_im_verein

    post "/api/v2/admin/players/#{spieler.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :success
    assert spieler.reload.deactivated_at.present?

    post "/api/v2/admin/players/#{spieler.id}/reactivate"
    assert_response :success
    assert_nil spieler.reload.deactivated_at
  end
end
