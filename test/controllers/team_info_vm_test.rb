require 'test_helper'

# Name und Kürzel der Mannschaft in der Hand des Vereins.
#
# Drei Rechte, die auseinandergehalten werden müssen: `:update_team` (Liga,
# Pokal-Ligen, Verein) bleibt beim Verband, `:update_team_info` (Name, Kürzel)
# und `:update_team_logo` bekommt auch der Vereinsmanager. Für ihn hängen die
# beiden letzten zusätzlich am Spielkalender: Bis zum ersten Spieltag darf er
# immer, danach nur, solange der Landesverband es zulässt.
class TeamInfoVmTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, game_operation: @go)
    @team = create(:team, league: @league, club: @club, name: 'Alpha', short_name: 'ALP')
  end

  # --- Schreibzugriff --------------------------------------------------------

  test 'VM des Vereins ändert Name und Kürzel' do
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info",
          params: { team: { name: 'Alpha Löwen', short_name: 'ALW II' } }

    assert_response :success
    assert_equal 'Alpha Löwen', @team.reload.name
    assert_equal 'ALW II', @team.short_name
    body = JSON.parse(response.body)
    assert_equal 'Alpha Löwen', body['name']
    assert body['manage_info']
  end

  test 'VM eines Verbund-Vereins ändert die Verbundmannschaft' do
    partner = create(:club, game_operation: @go)
    syndicate = create(:team, league: @league, club: @club, name: 'Beta',
                             syndicate: true, syndicate_clubs: [partner.id])
    login(create(:user, :vm, club_id: partner.id))

    patch "/api/v2/admin/teams/#{syndicate.id}/info", params: { team: { name: 'Beta Verbund' } }

    assert_response :success
    assert_equal 'Beta Verbund', syndicate.reload.name
  end

  test 'VM eines fremden Vereins und TM der Mannschaft dürfen nicht' do
    login(create(:user, :vm, club_id: create(:club, game_operation: @go).id))
    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Fremd' } }
    assert_response :forbidden

    login(create(:user, :tm, team_id: @team.id))
    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Teammanager' } }
    assert_response :forbidden

    assert_equal 'Alpha', @team.reload.name
  end

  test 'SBK des Spielbetriebs ändert weiterhin' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Vom Verband' } }

    assert_response :success
    assert_equal 'Vom Verband', @team.reload.name
  end

  # Der eigentliche Grund für den eigenen Endpunkt: Über #admin_team_update
  # liefe der Spielbetrieb mit im Formular.
  test 'Der Weg schreibt ausschließlich Name und Kürzel' do
    fremde_liga = create(:league, game_operation: create(:game_operation,
                                                         state_association_id: create(:state_association).id))
    fremder_verein = create(:club, game_operation: @go)
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info",
          params: { team: { name: 'Nur der Name', league_id: fremde_liga.id,
                            club_id: fremder_verein.id, cup_leagues: [fremde_liga.id] } }

    assert_response :success
    @team.reload
    assert_equal 'Nur der Name', @team.name
    assert_equal @league.id, @team.league_id
    assert_equal @club.id, @team.club_id
    assert_empty @team.cup_leagues
  end

  test 'Ein zu langes Kürzel wird abgewiesen' do
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { short_name: 'VIEL ZU LANG' } }

    assert_response :unprocessable_entity
    assert_equal 'ALP', @team.reload.short_name
    # Der ErrorInterceptor des Frontends liest `message`; ohne das stuende in
    # der Maske nur sein allgemeiner Satz statt der Grenze.
    assert_match(/8/, JSON.parse(response.body)['message'])
  end

  test 'Ein leerer Name wird abgewiesen' do
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: '' } }

    assert_response :unprocessable_entity
    assert_equal 'Alpha', @team.reload.name
  end

  # --- Frist und Verbandsschalter -------------------------------------------

  test 'Vor dem ersten Spieltag darf der Verein auch bei abgeschaltetem Verband' do
    @sa.update!(team_info_editable_during_season: false)
    create(:game_day, league: @league, date: (Date.current + 7).to_s)
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Vor dem Auftakt' } }

    assert_response :success
    assert_equal 'Vor dem Auftakt', @team.reload.name
  end

  test 'Nach dem ersten Spieltag sperrt der abgeschaltete Verband Name, Kürzel und Logo' do
    @sa.update!(team_info_editable_during_season: false)
    create(:game_day, league: @league, date: (Date.current - 1).to_s)
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Mitten in der Saison' } }
    assert_response :forbidden

    delete "/api/v2/admin/teams/#{@team.id}/logo"
    assert_response :forbidden

    assert_equal 'Alpha', @team.reload.name
  end

  test 'Der Spieltag selbst zählt bereits als gelaufen' do
    @sa.update!(team_info_editable_during_season: false)
    create(:game_day, league: @league, date: Date.current.to_s)
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Am Spieltag' } }

    assert_response :forbidden
  end

  test 'Mit eingeschaltetem Verband bleibt es auch nach dem ersten Spieltag erlaubt' do
    create(:game_day, league: @league, date: (Date.current - 7).to_s)
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Standard ist an' } }

    assert_response :success
    assert_equal 'Standard ist an', @team.reload.name
  end

  test 'Die Frist gilt nur dem Verein, nicht dem Verband' do
    @sa.update!(team_info_editable_during_season: false)
    create(:game_day, league: @league, date: (Date.current - 1).to_s)
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Berichtigung' } }

    assert_response :success
    assert_equal 'Berichtigung', @team.reload.name
  end

  # Ein untergeordneter Landesverband hat den Block „Einstellungen" nicht selbst
  # in der Hand, er kommt vom Verbund.
  test 'Der untergeordnete Landesverband erbt den Schalter seines Verbunds' do
    verbund = create(:state_association, team_info_editable_during_season: false)
    @sa.update!(parent_id: verbund.id, team_info_editable_during_season: true)
    create(:game_day, league: @league, date: (Date.current - 1).to_s)
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Vom Verbund gesperrt' } }

    assert_response :forbidden
  end

  # game_days.date ist eine Textspalte, und im Altbestand steht dort nicht immer
  # ein brauchbares Datum. Ein solcher Eintrag darf die Prüfung weder zum
  # Serverfehler machen noch stillschweigend sperren. Per update_column
  # hergestellt, weil die Maske so etwas nicht mehr entstehen lässt.
  test 'Ein krummes Spieltagsdatum sperrt nicht' do
    @sa.update!(team_info_editable_during_season: false)
    create(:game_day, league: @league).update_column(:date, 'unbekannt')
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Trotz krummem Datum' } }

    assert_response :success
  end

  # Die Maske listet nur die laufende Saison. Der Endpunkt darf sich darauf
  # nicht verlassen: Sonst benennt ein direkter Aufruf Mannschaften vergangener
  # Saisons um, und damit aendern sich rueckwirkend oeffentlich archivierte
  # Tabellen, Spielplaene und Spielberichte.
  test 'Vergangene Saisons bleiben dem Verein verschlossen' do
    alt = create(:team, league: create(:league, :previous_season, game_operation: @go),
                        club: @club, name: 'Vorsaison')
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{alt.id}/info", params: { team: { name: 'Nachtraeglich' } }

    assert_response :forbidden
    assert_equal 'Vorsaison', alt.reload.name
  end

  test 'Der Verband berichtigt auch im Archiv' do
    alt = create(:team, league: create(:league, :previous_season, game_operation: @go),
                        club: @club, name: 'Vorsaison')
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    patch "/api/v2/admin/teams/#{alt.id}/info", params: { team: { name: 'Berichtigt' } }

    assert_response :success
    assert_equal 'Berichtigt', alt.reload.name
  end

  # Massgeblich ist die Hauptliga. Der Pokal-Verband kann die Meldung des
  # Vereins nicht sperren, dort ist die Mannschaft Gast.
  test 'Der Schalter der Pokal-Liga eines fremden Verbands greift nicht' do
    pokal_sa = create(:state_association, team_info_editable_during_season: false)
    pokal_go = create(:game_operation, state_association_id: pokal_sa.id)
    pokal = create(:league, game_operation: pokal_go)
    create(:game_day, league: pokal, date: (Date.current - 7).to_s)
    @team.update!(cup_leagues: [pokal.id])
    login(create(:user, :vm, club_id: @club.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Trotz Pokal' } }

    assert_response :success
    assert_equal 'Trotz Pokal', @team.reload.name
  end

  # Abgrenzung zum Verbund-Test oben: Ohne gesetztes `syndicate`-Flag zaehlt
  # `syndicate_clubs` nicht mit (Team#all_club_ids), ein Altbestandseintrag
  # verschafft dem Ex-Partner also keinen Zugriff.
  test 'syndicate_clubs ohne Verbund-Flag verschafft keinen Zugriff' do
    partner = create(:club, game_operation: @go)
    @team.update!(syndicate: false, syndicate_clubs: [partner.id])
    login(create(:user, :vm, club_id: partner.id))

    patch "/api/v2/admin/teams/#{@team.id}/info", params: { team: { name: 'Ex-Partner' } }

    assert_response :forbidden
  end

  # --- Mannschaftsliste des Vereins -----------------------------------------

  test 'admin_club_teams meldet manage_info je Mannschaft' do
    @sa.update!(team_info_editable_during_season: false)
    gesperrt = @team
    create(:game_day, league: @league, date: (Date.current - 1).to_s)
    offen = create(:team, league: create(:league, game_operation: @go), club: @club, name: 'Ohne Spieltag')
    login(create(:user, :vm, club_id: @club.id))

    get "/api/v2/admin/clubs/#{@club.id}/teams"

    assert_response :success
    by_id = JSON.parse(response.body).index_by { |t| t['id'] }
    assert_not by_id[gesperrt.id]['manage_info']
    assert_not by_id[gesperrt.id]['manage_logo']
    assert by_id[gesperrt.id]['info_locked_by_season']
    assert by_id[offen.id]['manage_info']
    assert_not by_id[offen.id]['info_locked_by_season']
    assert_equal 'ALP', by_id[gesperrt.id]['short_name']
  end

  # Die Sperrbegruendung meint „DIESE Person darf gerade deshalb nicht" und
  # nicht die Sperre an sich. Verband und SBK duerfen trotz gesetzter Sperre,
  # fuer sie waere die Begruendung genauso falsch herum wie fuer den Verein die
  # fremde Liga.
  test 'admin_club_teams meldet dem Verband keine Sperrbegruendung' do
    @sa.update!(team_info_editable_during_season: false)
    create(:game_day, league: @league, date: (Date.current - 1).to_s)
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    get "/api/v2/admin/clubs/#{@club.id}/teams"

    assert_response :success
    entry = JSON.parse(response.body).find { |t| t['id'] == @team.id }
    assert entry['manage_info']
    assert_not entry['info_locked_by_season']
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
