require 'test_helper'

# Rechte-Scope der Spielersperren. Vorher entschied der `game_operations_hash`
# des Vereins, also auch bloße Gast-Einträge aus dem Altdaten-Import 2010–2014.
# Zuständig ist jetzt der Spielbetrieb, der sich aus dem Landesverband des
# Vereins ergibt (Club#main_game_operation_id).
#
# Der Verein im Setup trägt bewusst einen WIDERSPRECHENDEN Alt-Eintrag: Die
# Spalte existiert weiter und hat auf Produktion noch Werte, also muss ein Test
# festhalten, dass sie hier nichts mehr entscheidet.
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

      # Alt-Eintrag auf @fremd_go, Landesverband auf @heim_sa: Der Hash widerspricht
      # der Zuständigkeit, und @heim_go muss gewinnen.
      @club = create(:club, state_association_id: @heim_sa.id,
                            game_operations_hash: [{ 'game_operation_id' => @fremd_go.id,
                                                     'home_game_operation' => true }])
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

    # Kern der Umstellung: Der Alt-Eintrag gibt kein Sperrrecht mehr, obwohl er
    # @fremd_go ausdruecklich als Heimat nennt.
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
  end
end
