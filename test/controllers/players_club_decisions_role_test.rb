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

  # --- Freigabe durch den Verein ------------------------------------------------
  #
  # `clubs.team_managers_manage_players`: Der Verein entscheidet, ob seine
  # Teammanager*innen den Bestand pflegen. Ohne den Schalter gilt alles oben,
  # mit ihm gelten für den TM in diesem Verein dieselben Endpunkte wie für den
  # VM. Der Schalter selbst bleibt ihm verschlossen (clubs_controller_test).

  def tm_im_freigegebenen_verein
    @club.update!(team_managers_manage_players: true)
    team = create(:team, club: @club, league: create(:league, :current_season))
    create(:user, :tm, team_id: team.id)
  end

  test 'Teammanager legt an, wenn der Verein es freigegeben hat' do
    login_as(tm_im_freigegebenen_verein)

    assert_difference 'Player.count', 1 do
      anlegen(@club.id)
    end

    assert_response :created
    assert_equal @club.id, Player.last.clubs.first['club_id']
  end

  test 'Teammanager deaktiviert und reaktiviert, wenn der Verein es freigegeben hat' do
    login_as(tm_im_freigegebenen_verein)
    spieler = spieler_im_verein

    post "/api/v2/admin/players/#{spieler.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :success
    assert spieler.reload.deactivated_at.present?

    post "/api/v2/admin/players/#{spieler.id}/reactivate"
    assert_response :success
    assert_nil spieler.reload.deactivated_at
  end

  # Der Schalter hängt am Verein und nicht am Konto. Für die Deaktivierung ist
  # das die eigentliche Prüfung: Der Verein kommt dort nicht aus dem Aufruf,
  # sondern aus der Zugehörigkeit der Person, und ein Konto kann für
  # Mannschaften mehrerer Vereine zuständig sein.
  test 'Freigabe eines Vereins oeffnet nicht den anderen' do
    frei = create(:club, team_managers_manage_players: true)
    league = create(:league, :current_season)
    team_frei = create(:team, club: frei, league:)
    team_gesperrt = create(:team, club: @club, league:)
    user = create(:user, :tm, team_id: team_frei.id)
    user.update!(teams: [team_frei.id, team_gesperrt.id])
    login_as(user)

    gesperrt_spieler = spieler_im_verein
    frei_spieler = create(:player, clubs: [{ 'club_id' => frei.id, 'home_club' => true,
                                             'created_at' => 1.year.ago.iso8601 }])

    post "/api/v2/admin/players/#{gesperrt_spieler.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :forbidden
    assert_nil gesperrt_spieler.reload.deactivated_at

    post "/api/v2/admin/players/#{frei_spieler.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :success

    assert_no_difference 'Player.count' do
      anlegen(@club.id)
    end
    assert_response :forbidden

    assert_difference 'Player.count', 1 do
      anlegen(frei.id)
    end
    assert_response :created
  end

  # Die Freigabe gilt für die Mannschaften DIESES Vereins. Ein fremder
  # Teammanager bekommt durch sie nichts -- sonst wäre der Schalter kein
  # Vereinsrecht, sondern ein offenes Tor.
  test 'Freigabe erteilt einem fremden Teammanager nichts' do
    @club.update!(team_managers_manage_players: true)
    fremdes_team = create(:team, club: create(:club), league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: fremdes_team.id))
    spieler = spieler_im_verein

    assert_no_difference 'Player.count' do
      anlegen(@club.id)
    end
    assert_response :forbidden

    post "/api/v2/admin/players/#{spieler.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :forbidden
    assert_nil spieler.reload.deactivated_at
  end

  # Das Spielerprofil zeigt dieselben Knöpfe wie die Vereinsliste. Weil die
  # Freigabe am Verein hängt, kann das Rollen-Flag im Browser sie nicht
  # steuern; die Antwort zum Profil sagt es deshalb je Profil.
  test 'Profil nennt dem Teammanager, ob er deaktivieren darf' do
    login_as(tm_im_freigegebenen_verein)
    spieler = spieler_im_verein

    get "/api/v2/admin/players/#{spieler.id}.json"

    assert_response :success
    assert_equal true, JSON.parse(response.body)['can_deactivate']
  end

  test 'Profil verneint es dem Teammanager ohne Freigabe' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))
    spieler = spieler_im_verein

    get "/api/v2/admin/players/#{spieler.id}.json"

    assert_response :success
    assert_equal false, JSON.parse(response.body)['can_deactivate']
  end

  # Die Maske uebernimmt die Antwort auf die Aktion ungefiltert
  # (`this.player = updated`) und leitet den Gegenknopf daraus ab. Trug sie das
  # Feld nicht, griff dort der Rueckfall auf das globale Rollen-Flag
  # `player_deactivate` -- und das ist fuer einen reinen Teammanager false.
  # Nach dem Deaktivieren fehlte ihm deshalb „Reaktivieren", bis die Seite neu
  # geladen wurde, und umgekehrt genauso.
  test 'Antwort auf Deaktivieren und Reaktivieren nennt den Gegenknopf' do
    login_as(tm_im_freigegebenen_verein)
    spieler = spieler_im_verein

    post "/api/v2/admin/players/#{spieler.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :success
    assert_equal true, JSON.parse(response.body)['can_deactivate']

    post "/api/v2/admin/players/#{spieler.id}/reactivate"
    assert_response :success
    assert_equal true, JSON.parse(response.body)['can_deactivate']
  end

  # Gegenprobe zur Deaktivierung ohne Freigabe: Auch die Ruecknahme ist eine
  # Vereinsentscheidung. Ohne diesen Fall war `reactivate` allein im Happy Path
  # belegt.
  test 'Teammanager reaktiviert ohne Freigabe nicht' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))
    spieler = spieler_im_verein(deactivated_at: 2.days.ago)

    post "/api/v2/admin/players/#{spieler.id}/reactivate"

    assert_response :forbidden
    assert_match 'Vereinsverwaltung', JSON.parse(response.body)['message']
    assert spieler.reload.deactivated_at.present?
  end

  # Die Absage muss den Weg nennen: Ohne den Hinweis auf die Vereinsverwaltung
  # erfährt ein Teammanager nirgends, dass sich daran etwas ändern lässt.
  test 'Absage nennt die Vereinsverwaltung als Weg' do
    team = create(:team, club: @club, league: create(:league, :current_season))
    login_as(create(:user, :tm, team_id: team.id))
    spieler = spieler_im_verein

    anlegen(@club.id)
    assert_response :forbidden
    assert_match 'Vereinsverwaltung', JSON.parse(response.body)['message']

    post "/api/v2/admin/players/#{spieler.id}/deactivate", params: { reason: 'Karriereende' }
    assert_response :forbidden
    assert_match 'Vereinsverwaltung', JSON.parse(response.body)['message']
  end
end
