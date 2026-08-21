require 'test_helper'

# `cup_leagues` darf eine Liga aus einem fremden Spielbetrieb enthalten, sobald
# die aufnehmende Stelle sie verwalten darf (Pokal des Bundesverbands). Ein
# Landesverband kann weiterhin keine fremde Liga eintragen, muss seine eigene
# Mannschaft aber weiter speichern koennen, nachdem der Bundesverband sie in
# seinen Pokal aufgenommen hat.
class TeamsCupLeagueScopeTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @fd_go = create(:game_operation, :national)
    @cup = create(:league, game_operation: @fd_go, name: 'FD-Pokal')

    @lv_go = create(:game_operation)
    @lv_league = create(:league, game_operation: @lv_go, name: 'Regionalliga Ost')
    @other_lv_league = create(:league, game_operation: @lv_go, name: 'Landesliga Ost')
    @club = create(:club)
    @team = create(:team, league: @lv_league, club: @club, name: 'Berlin Rockets')
  end

  test 'bundesweiter Admin darf den fremden Pokal in cup_leagues schreiben' do
    login(create(:user, :admin))

    post '/api/v2/admin/teams', params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [@cup.id] } }, as: :json

    assert_response :success
    assert_includes @team.reload.cup_leagues, @cup.id
  end

  test 'LV-SBK darf keine Liga eines fremden Spielbetriebs neu eintragen' do
    login(create(:user, :sbk_scoped, game_operation_id: @lv_go.id))

    post '/api/v2/admin/teams', params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [@cup.id] } }, as: :json

    assert_response :unprocessable_entity
    assert_empty @team.reload.cup_leagues.to_a
  end

  test 'LV-SBK darf seine eigene Mannschaft weiter speichern, wenn der Pokal schon eingetragen ist' do
    @team.update!(cup_leagues: [@cup.id])
    login(create(:user, :sbk_scoped, game_operation_id: @lv_go.id))

    post '/api/v2/admin/teams',
         params: { id: @team.id, league_id: @lv_league.id, team: { name: 'Berlin Rockets II', cup_leagues: [@cup.id] } }, as: :json

    assert_response :success
    @team.reload
    assert_equal 'Berlin Rockets II', @team.name
    assert_includes @team.cup_leagues, @cup.id, 'Der Pokal-Eintrag darf beim Speichern nicht verloren gehen'
  end

  test 'LV-SBK darf eine Liga des eigenen Spielbetriebs weiter eintragen' do
    login(create(:user, :sbk_scoped, game_operation_id: @lv_go.id))

    post '/api/v2/admin/teams', params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [@other_lv_league.id] } },
         as: :json

    assert_response :success
    assert_includes @team.reload.cup_leagues, @other_lv_league.id
  end

  # Das Austragen war die ungeschuetzte Richtung: Aufnehmen und Entfernen ueber
  # den Wettbewerb verlangen Rechte auf ihm, ein verkuerztes cup_leagues im
  # Mannschafts-PUT ging ohne jede Pruefung durch.
  test 'LV-SBK darf die Mannschaft nicht per verkuerztem cup_leagues aus dem fremden Pokal nehmen' do
    @team.update!(cup_leagues: [@cup.id])
    login(create(:user, :sbk_scoped, game_operation_id: @lv_go.id))

    post '/api/v2/admin/teams',
         params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [] } }, as: :json

    assert_response :forbidden
    assert_includes @team.reload.cup_leagues, @cup.id
  end

  test 'LV-SBK darf eine Liga des eigenen Spielbetriebs wieder austragen' do
    @team.update!(cup_leagues: [@other_lv_league.id])
    login(create(:user, :sbk_scoped, game_operation_id: @lv_go.id))

    post '/api/v2/admin/teams',
         params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [] } }, as: :json

    assert_response :success
    assert_empty @team.reload.cup_leagues.to_a
  end

  test 'bundesweiter Admin darf den eigenen Pokal wieder austragen' do
    @team.update!(cup_leagues: [@cup.id])
    login(create(:user, :admin))

    post '/api/v2/admin/teams',
         params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [] } }, as: :json

    assert_response :success
    assert_empty @team.reload.cup_leagues.to_a
  end

  # Ein Eintrag, dessen Liga es nicht mehr gibt, soll beim naechsten Speichern
  # ausfallen und nicht durch den Bestandsschutz konserviert werden.
  test 'ein Eintrag auf eine geloeschte Liga bleibt unzulaessig' do
    dead = create(:league, game_operation: @lv_go)
    @team.update!(cup_leagues: [dead.id])
    dead_id = dead.id
    dead.destroy!
    login(create(:user, :admin))

    post '/api/v2/admin/teams',
         params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [dead_id] } }, as: :json

    assert_response :unprocessable_entity
  end

  test 'eine ins Leere zeigende Liga-ID bleibt unzulaessig' do
    login(create(:user, :admin))

    post '/api/v2/admin/teams', params: { id: @team.id, league_id: @lv_league.id, team: { cup_leagues: [999_999] } }, as: :json

    assert_response :unprocessable_entity
    assert_empty @team.reload.cup_leagues.to_a
  end

  test 'beim Anlegen darf der bundesweite Admin den fremden Pokal mitgeben' do
    login(create(:user, :admin))

    post '/api/v2/admin/teams',
         params: { id: 0, league_id: @lv_league.id,
                   team: { name: 'Dresden Tigers', club_id: @club.id, league_id: @lv_league.id,
                           cup_leagues: [@cup.id] } },
         as: :json

    assert_response :created
    assert_includes Team.find(JSON.parse(response.body)['id']).cup_leagues, @cup.id
  end

  # Die Vereinsauswahl der Liga (Ausrichter eines Spieltags, Verein einer neuen
  # Mannschaft) leitete sich aus `Team.where(league_id:)` ab und kannte damit
  # keine per cup_leagues aufgenommene Mannschaft.
  test 'Vereinsauswahl der Liga enthaelt den Verein einer per cup_leagues aufgenommenen Mannschaft' do
    # Bewusst ein Pokal in einem nicht-bundesweiten Spielbetrieb und ein darauf
    # begrenzter SBK: Sonst griffe der globale Zweig und der Test bewiese nichts
    # ueber die Ableitung aus den Mannschaften der Liga.
    lv_cup_go = create(:game_operation)
    lv_cup = create(:league, game_operation: lv_cup_go, name: 'Ost-Pokal')
    @team.update!(cup_leagues: [lv_cup.id])
    login(create(:user, :sbk_scoped, game_operation_id: lv_cup_go.id))

    get "/api/v2/admin/league/clubs/l/#{lv_cup.id}"

    assert_response :success
    assert_includes JSON.parse(response.body).map { |c| c['id'] }, @club.id
  end

  # Der Fall einer Mannschaft, die ausschliesslich den Pokal spielt: Sie muss im
  # Wettbewerb erst angelegt werden, und dafuer braucht die Maske eine
  # Vereinsauswahl. Der Bundesverband hat kaum eigene Heim-Vereine, ohne den
  # globalen Zweig blieb die Liste leer.
  test 'bundesweiter Zugriff sieht in einem leeren Wettbewerb trotzdem Vereine' do
    login(create(:user, :sbk_scoped, game_operation_id: @fd_go.id))

    get "/api/v2/admin/league/clubs/l/#{@cup.id}"

    assert_response :success
    assert_includes JSON.parse(response.body).map { |c| c['id'] }, @club.id
  end

  test 'deaktivierte Vereine bleiben aus der bundesweiten Auswahl heraus' do
    gone = create(:club, deactivated_at: Time.current)
    login(create(:user, :sbk_scoped, game_operation_id: @fd_go.id))

    get "/api/v2/admin/league/clubs/l/#{@cup.id}"

    assert_response :success
    assert_not_includes JSON.parse(response.body).map { |c| c['id'] }, gone.id
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
