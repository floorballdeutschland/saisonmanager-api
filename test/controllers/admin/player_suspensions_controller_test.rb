require 'test_helper'

# Rechte-Scope der Spielersperren. Vorher entschied der `game_operations_hash`
# des Vereins, also auch bloße Gast-Einträge aus dem Altdaten-Import 2010–2014.
# Zuständig ist jetzt der Spielbetrieb, der sich aus dem Landesverband des
# Vereins ergibt (Club#main_game_operation_id); die Spalte ist abgebaut.
#
# Neue Regel:
#   Lesen    – ein Verein des Spielers ist lesbar (zuständiger Spielbetrieb oder
#              Vereins-Freigabe), oder eine Lizenz hängt an einer eigenen Liga.
#   Sperren  – nur der Heimatverband. Eine Freigabe genügt NICHT, die ist
#              ausdrücklich nur lesend. Bei einer Sperre auf eine einzelne
#              Team-Lizenz zählt zusätzlich die Liga dieses Teams.
module Admin
  class PlayerSuspensionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      create(:setting)
      @heim_sa = create(:state_association)
      @heim_go = create(:game_operation, state_association_id: @heim_sa.id)
      @fremd_go = create(:game_operation)

      @club = create(:club, state_association_id: @heim_sa.id)
      assert_equal @heim_go.id, @club.main_game_operation_id
      @player = create(:player, clubs: [{ 'club_id' => @club.id, 'home_club' => true }])
    end

    def login(user)
      post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
      assert_response :success
    end

    def suspend(valid_until: 1.month.from_now.to_date, team_id: nil)
      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { valid_until: valid_until.to_s, reason: 'Test', team_id: team_id }.compact
    end

    test 'Heimatverband darf spielerweit sperren' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))

      suspend

      assert_response :created
      assert_equal 'application_block', JSON.parse(response.body)['kind']
    end

    # Kern der Umstellung: Ein Spielbetrieb ohne Zustaendigkeit fuer den Verein
    # des Spielers hat kein Sperrrecht.
    test 'fremder Spielbetrieb darf nicht spielerweit sperren' do
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      suspend

      assert_response :forbidden
      assert_equal 0, @player.reload.suspensions.count
    end

    # Eine Freigabe erlaubt Lesen, aber kein Sperren – sie ist read-only.
    test 'Vereins-Freigabe erlaubt Lesen, aber kein Sperren' do
      empfaenger_go = create(:game_operation)
      StateAssociationRelease.create!(grantor_state_association_id: @heim_sa.id,
                                      recipient_game_operation_id: empfaenger_go.id,
                                      season_id: Setting.current_season_id)
      login(create(:user, :sbk_scoped, game_operation_id: empfaenger_go.id))

      get "/api/v2/admin/players/#{@player.id}/suspensions"
      assert_response :success

      suspend
      assert_response :forbidden
    end

    # Bei einer Sperre auf eine einzelne Team-Lizenz zaehlt die Liga des Teams:
    # Wer die Lizenz erteilt, darf sie auch aussetzen.
    test 'Liga-Spielbetrieb darf die Lizenz einer Gastmannschaft aussetzen' do
      liga = create(:league, :current_season, game_operation: @fremd_go)
      team = create(:team, league: liga, club: @club)
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      suspend(team_id: team.id)

      assert_response :created
      assert_equal 'license_suspension', JSON.parse(response.body)['kind']
    end

    # Gegenprobe zum vorherigen Fall: ohne Team bleibt es beim Heimatverband.
    test 'Liga-Spielbetrieb darf trotz eigener Liga nicht spielerweit sperren' do
      liga = create(:league, :current_season, game_operation: @fremd_go)
      create(:team, league: liga, club: @club)
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      suspend

      assert_response :forbidden
    end

    test 'Aufheben einer spielerweiten Sperre bleibt beim Heimatverband' do
      heim = create(:user, :sbk_scoped, game_operation_id: @heim_go.id)
      login(heim)
      suspend
      assert_response :created
      sperre_id = JSON.parse(response.body)['id']

      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))
      delete "/api/v2/admin/players/#{@player.id}/suspensions/#{sperre_id}"
      assert_response :forbidden

      login(heim)
      delete "/api/v2/admin/players/#{@player.id}/suspensions/#{sperre_id}"
      assert_response :success
      assert_not_nil JSON.parse(response.body)['lifted_at']
    end

    # Die team_id kommt aus den Parametern. Ohne Bindung an den Spieler koennte
    # eine SBK ein beliebiges Team ihrer eigenen Liga angeben und damit eine
    # Sperre auf einen voellig fremden Spieler schreiben - und ihn ueber
    # Player#suspended_for_team? dauerhaft von einer Lizenz aussperren.
    test 'Team-Sperre nur, wenn das Team auch zum Spieler gehoert' do
      liga = create(:league, :current_season, game_operation: @fremd_go)
      fremdes_team = create(:team, league: liga, club: create(:club))
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      suspend(team_id: fremdes_team.id)

      assert_response :forbidden
      assert_equal 0, @player.reload.suspensions.count
    end

    # Gegenprobe: Mit Lizenz fuer dieses Team greift es, auch ohne aktuelle
    # Vereinsmitgliedschaft im Verein des Teams.
    test 'Team-Sperre greift bei bestehender Lizenz fuer dieses Team' do
      liga = create(:league, :current_season, game_operation: @fremd_go)
      team = create(:team, league: liga, club: create(:club))
      @player.update!(licenses: [{ 'id' => 'L1', 'team_id' => team.id, 'history' => [] }])
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      suspend(team_id: team.id)

      assert_response :created
    end

    test 'globaler SBK und Admin duerfen weiterhin alles' do
      login(create(:user, :sbk_global))
      suspend
      assert_response :created

      login(create(:user, :admin))
      get "/api/v2/admin/players/#{@player.id}/suspensions"
      assert_response :success
    end

    test 'fremder Spielbetrieb ohne jeden Bezug darf auch nicht lesen' do
      login(create(:user, :sbk_scoped, game_operation_id: create(:game_operation).id))

      get "/api/v2/admin/players/#{@player.id}/suspensions"

      assert_response :forbidden
    end

    # -------------------------------------------------------------------------
    # Geltungsbereich und Dauer (#604)
    # -------------------------------------------------------------------------

    test 'Heimatverband darf eine Sperre auf einen Wettbewerb setzen' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))
      liga = create(:league, :current_season, game_operation: @heim_go, league_modus: 'league',
                                              age_group: 'Herren', field_size: 'GF')

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', league_id: liga.id, games_total: 3,
                     competition_groups: [League::GROUP_LIGA], reason: 'Tätlichkeit' }

      assert_response :created
      body = JSON.parse(response.body)
      assert_equal 'competition', body['scope_kind']
      assert_equal 3, body['games_total']
      assert_equal 3, body['remaining_games']
      assert_nil body['valid_until'], 'eine Sperre über Spiele braucht kein Enddatum'
      assert_equal "Herren Großfeld, Ligaspielbetrieb, #{@heim_go.name}", body['scope_summary']
    end

    # Eine Wettbewerbssperre greift in jeder Liga derselben Altersklasse, auch
    # in fremden Verbaenden. Sie bleibt deshalb dem Heimatverband vorbehalten.
    test 'Verband der Liga darf keine Wettbewerbssperre setzen' do
      liga = create(:league, :current_season, game_operation: @fremd_go, league_modus: 'league')
      team = create(:team, league: liga, club: @club)
      @player.update!(licenses: [{ 'id' => 'l1', 'team_id' => team.id, 'season_id' => '18',
                                   'history' => [{ 'license_status_id' => License::APPROVED,
                                                   'created_at' => 1.day.ago.iso8601 }] }])
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', league_id: liga.id, games_total: 2 }

      assert_response :forbidden
      assert_equal 0, @player.reload.suspensions.count
    end

    # Wer die Lizenz erteilt, darf sie aussetzen -- aber nur fuer einen Spieler,
    # der mit dieser Liga zu tun hat.
    test 'Verband der Liga darf auf seine Liga sperren' do
      liga = create(:league, :current_season, game_operation: @fremd_go, league_modus: 'league')
      team = create(:team, league: liga, club: @club)
      @player.update!(licenses: [{ 'id' => 'l1', 'team_id' => team.id, 'season_id' => '18',
                                   'history' => [{ 'license_status_id' => License::APPROVED,
                                                   'created_at' => 1.day.ago.iso8601 }] }])
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'league', league_id: liga.id, games_total: 1 }

      assert_response :created
      assert_equal 'league', JSON.parse(response.body)['scope_kind']
    end

    test 'Ligasperre auf einen Spieler ohne Bezug zur Liga wird abgelehnt' do
      liga = create(:league, :current_season, game_operation: @fremd_go, league_modus: 'league')
      create(:team, league: liga)
      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'league', league_id: liga.id, games_total: 1 }

      assert_response :forbidden
    end

    test 'eine Sperre ohne Enddatum und ohne Spiele wird abgelehnt' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))

      post "/api/v2/admin/players/#{@player.id}/suspensions", params: { reason: 'ohne Dauer' }

      assert_response :unprocessable_entity
      assert_match(/Enddatum oder eine Anzahl von Spielen/, JSON.parse(response.body)['message'])
    end

    test 'ein unlesbares Ablaufdatum wird abgelehnt' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))

      post "/api/v2/admin/players/#{@player.id}/suspensions", params: { valid_until: 'übermorgen' }

      assert_response :unprocessable_entity
    end

    test 'eine Wettbewerbssperre ohne Liga wird abgelehnt' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', games_total: 2 }

      assert_response :unprocessable_entity
      assert_match(/fehlt die Liga/, JSON.parse(response.body)['message'])
    end

    test 'alle Wettbewerbe abgewählt wird abgelehnt statt still vorbelegt' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))
      liga = create(:league, :current_season, game_operation: @heim_go, league_modus: 'league')

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', league_id: liga.id, games_total: 2,
                     competition_groups: [] }

      assert_response :unprocessable_entity
    end

    # -------------------------------------------------------------------------
    # Manuelles Aufheben (#605)
    # -------------------------------------------------------------------------

    test 'Sperre lässt sich mit Begründung aufheben' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))
      suspend
      suspension_id = JSON.parse(response.body)['id']

      delete "/api/v2/admin/players/#{@player.id}/suspensions/#{suspension_id}",
             params: { reason: 'Einspruch erfolgreich' }

      assert_response :success
      body = JSON.parse(response.body)
      assert_not body['active']
      assert_not_nil body['lifted_at']
    end

    test 'fremder Spielbetrieb darf eine Wettbewerbssperre nicht aufheben' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))
      # Vorlage aus dem EIGENEN Spielbetrieb: Eine fremde Liga als Vorlage
      # anzugeben ist der SBK verwehrt, siehe den Test darunter.
      liga = create(:league, :current_season, game_operation: @heim_go, league_modus: 'league',
                                              age_group: 'Herren', field_size: 'GF')
      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', league_id: liga.id, games_total: 2 }
      assert_response :created
      suspension_id = JSON.parse(response.body)['id']

      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))
      delete "/api/v2/admin/players/#{@player.id}/suspensions/#{suspension_id}"

      assert_response :forbidden
      assert PlayerSuspension.find(suspension_id).active?
    end

    # Die angegebene Liga ist die Vorlage fuer Altersklasse, Feldgroesse UND
    # Spielbetrieb der Sperre. Eine fremde Vorlage haette eine Sperre erzeugt,
    # die in fremden Ligen greift und in den eigenen gerade nicht -- und damit
    # den Riegel auf `all_game_operations` umgangen, ohne ihn zu setzen.
    test 'SBK kann keine Liga eines fremden Spielbetriebs als Vorlage nehmen' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))
      fremde_liga = create(:league, :current_season, game_operation: @fremd_go,
                                                     league_modus: 'league',
                                                     age_group: 'Herren', field_size: 'GF')

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', league_id: fremde_liga.id, games_total: 2 }

      assert_response :forbidden
      assert_equal 0, @player.reload.suspensions.count
    end

    # Beim Aufheben kommt die Liga aus der GESPEICHERTEN Sperre, nicht aus den
    # Parametern. Sonst suchte sich der Antragsteller selbst aus, gegen welche
    # Liga sein Recht geprueft wird: Eine SBK West haette eine Ligasperre der
    # SBK Ost aufgehoben, indem sie eine EIGENE Liga mitschickt, in der der
    # Spieler zufaellig eine Lizenz haelt.
    test 'mitgeschickte league_id verschafft kein Recht zum Aufheben' do
      # Ligasperre der SBK Ost auf ihre eigene Liga.
      ost_liga = create(:league, :current_season, game_operation: @heim_go, league_modus: 'league')
      ost_team = create(:team, league: ost_liga, club: @club)
      @player.update!(licenses: [{ 'id' => 'ost', 'team_id' => ost_team.id, 'season_id' => '18',
                                   'history' => [{ 'license_status_id' => License::APPROVED,
                                                   'created_at' => 1.day.ago.iso8601 }] }])
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))
      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'league', league_id: ost_liga.id, games_total: 1 }
      assert_response :created
      suspension_id = JSON.parse(response.body)['id']

      # Die SBK West hat eine eigene Liga, in der derselbe Spieler antritt.
      west_liga = create(:league, :current_season, game_operation: @fremd_go, league_modus: 'league')
      west_team = create(:team, league: west_liga, club: @club)
      @player.update!(licenses: @player.reload.licenses + [
        { 'id' => 'west', 'team_id' => west_team.id, 'season_id' => '18',
          'history' => [{ 'license_status_id' => License::APPROVED,
                          'created_at' => 1.day.ago.iso8601 }] }
      ])

      login(create(:user, :sbk_scoped, game_operation_id: @fremd_go.id))
      delete "/api/v2/admin/players/#{@player.id}/suspensions/#{suspension_id}",
             params: { league_id: west_liga.id }

      assert_response :forbidden
      assert PlayerSuspension.find(suspension_id).active?, 'die fremde Sperre muss stehen bleiben'
    end

    # Die Entgrenzung des Spielbetriebs bleibt der Bundesadministration
    # vorbehalten: Eine Sperre ohne Grenze greift in jedem Verband derselben
    # Altersklasse, und die SBK hat ihre Weisungsbefugnis nur im eigenen
    # Spielbetrieb (Rueckmeldung der SBK FD vom 04.09.2026).
    test 'SBK kann die Spielbetriebs-Grenze nicht abwaehlen' do
      login(create(:user, :sbk_scoped, game_operation_id: @heim_go.id))
      liga = create(:league, :current_season, game_operation: @heim_go, league_modus: 'league',
                                              age_group: 'Herren', field_size: 'GF')

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', league_id: liga.id, games_total: 2,
                     all_game_operations: true }

      assert_response :created
      assert_equal @heim_go.id, JSON.parse(response.body)['game_operation_id']
    end

    test 'Admin darf die Sperre ueber alle Spielbetriebe legen' do
      login(create(:user, :admin))
      liga = create(:league, :current_season, game_operation: @heim_go, league_modus: 'league',
                                              age_group: 'Herren', field_size: 'GF')

      post "/api/v2/admin/players/#{@player.id}/suspensions",
           params: { scope_kind: 'competition', league_id: liga.id, games_total: 2,
                     all_game_operations: true }

      assert_response :created
      body = JSON.parse(response.body)
      assert_nil body['game_operation_id']
      assert_match(/alle Spielbetriebe/, body['scope_summary'])
    end
  end
end
