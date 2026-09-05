require 'test_helper'

# handle_license_request hat lange auf alles mit `success: true` geantwortet,
# auch wenn es nichts getan hat: Eine unbekannte Lizenz-id lief in ein `map!`,
# das nichts fand, ein nicht vorgesehener Zielstatus in eine Bedingung, die
# nicht griff. Die Oberfläche zeigte dann eine Bestätigung für einen Wechsel,
# den es nie gab. Hier steht, was der Endpunkt seither beantwortet.
#
# Eigene Datei, weil players_controller_test.rb nahe an Metrics/ClassLength
# (Max 1000, .rubocop_todo.yml) liegt.
class PlayersLicenseStatusTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @game_operation = create(:game_operation)
    @club = create(:club)
    @league = create(:league, :current_season, game_operation: @game_operation)
    @team = create(:team, league: @league, club: @club)
    @player = create(:player,
                     clubs: [{ 'club_id' => @club.id, 'home_club' => true,
                               'created_at' => 1.day.ago.iso8601 }])
    login_as(create(:user, :admin))
  end

  def login_as(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }, as: :json
    assert_response :success
  end

  def license_with(history)
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id,
                                 'league_class_id' => @league.league_class_id,
                                 'history' => history }])
    id
  end

  def approved
    license_with([
      { 'license_status_id' => License::REQUESTED, 'created_at' => 3.days.ago.iso8601 },
      { 'license_status_id' => License::APPROVED, 'created_at' => 2.days.ago.iso8601 }
    ])
  end

  def handle(license_id, status, reason: 'Grund')
    post "/api/v2/admin/players/#{@player.id}/handle_license_request",
         params: { license_id: license_id, license_status_id: status, reason: reason },
         as: :json
  end

  def history
    @player.reload.licenses.first['history']
  end

  test 'eine unbekannte Lizenz-id wird beantwortet, nicht bestätigt' do
    approved

    handle('gibt-es-nicht', License::APPROVED)

    assert_response :not_found
    assert_equal 2, history.size, 'an der vorhandenen Lizenz darf sich nichts ändern'
  end

  # Der Sperr-Status hängt an einer Sperre mit Laufzeit (Player#suspend!) und
  # gehört nicht an diesen Endpunkt. Früher meldete er trotzdem Erfolg.
  test 'ein nicht vorgesehener Zielstatus wird abgelehnt' do
    license_id = approved

    handle(license_id, License::SUSPENDED)

    assert_response :unprocessable_entity
    assert_equal 2, history.size
    assert_equal License::APPROVED, history.last['license_status_id'].to_i
  end

  test 'der Altbestands-Status ignoriert bekommt keinen neuen Schreibweg' do
    license_id = approved

    handle(license_id, License::IGNORED)

    assert_response :unprocessable_entity
    assert_equal 2, history.size
  end

  # Der harmlose Fall bleibt harmlos: Ein Doppelklick oder eine veraltete Zeile
  # in der Lizenzliste schickt denselben Status noch einmal. Das ist kein
  # Fehler, schreibt aber auch keinen zweiten Eintrag.
  test 'derselbe Status noch einmal gesetzt ändert nichts und meldet keinen Fehler' do
    license_id = approved

    handle(license_id, License::APPROVED)

    assert_response :ok
    assert_equal 2, history.size
  end

  # Auf Produktiv gibt es zwei Lizenzen ohne jeden Verlauf. Der frühere Leser
  # (`history.sort_by { .. }.last['license_status_id']`) lief dort auf nil und
  # damit in einen 500.
  test 'eine Lizenz ohne Verlauf führt nicht mehr zu einem Serverfehler' do
    license_id = license_with([])

    handle(license_id, License::APPROVED)

    assert_response :ok
    assert_equal 1, history.size
    assert_equal License::APPROVED, history.last['license_status_id'].to_i
  end

  test 'eine Lizenz ohne History-Schlüssel führt nicht mehr zu einem Serverfehler' do
    id = Digest::UUID.uuid_v4
    @player.update!(licenses: [{ 'id' => id, 'team_id' => @team.id,
                                 'season_id' => @league.season_id }])

    handle(id, License::DENIED)

    assert_response :ok
    assert_equal License::DENIED, history.last['license_status_id'].to_i
  end
end
