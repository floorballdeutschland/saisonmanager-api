require 'test_helper'

# Eine Sperre über X Spiele zählt ab, sobald der Spielbericht abgeschlossen ist
# (#604). Der Zählpunkt sitzt im Endpunkt für den Spielstatus, damit er genau
# einmal je Spiel fällt -- und nicht an einem Cron, der die Sperre erst am
# nächsten Morgen kürzer machen würde.
class GamesSuspensionCountdownTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @go = create(:game_operation, state_association_id: create(:state_association).id)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    @club = create(:club)
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club,
                                number: 1, date: Date.current.to_s)
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: @club)
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                         started: true, ended: true, forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] },
                         special_event: true, referee1_string: '12345 Eree, Ref')
    RefereeAssignment.create!(game: @game, referee1_id: create(:referee).id,
                              referee2_id: create(:referee).id, status: 'published')

    @player = create(:player, with_licenses: [{ team: @home, status: License::APPROVED }])
    @admin = create(:user, :admin)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def close_match_record
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'match_record_closed' }
  end

  test 'das Abschließen des Spielberichts zählt ein Spiel der Sperre ab' do
    suspension = @player.suspend!(user_id: @admin.id, team_id: @home.id, games_total: 2)
    login(@admin)

    close_match_record

    assert_response :success
    assert_equal 1, suspension.reload.games_served
    assert_equal 1, suspension.remaining_games
    assert suspension.active?
  end

  test 'das letzte abgesessene Spiel hebt die Sperre auf und die Lizenz gilt wieder' do
    suspension = @player.suspend!(user_id: @admin.id, team_id: @home.id, games_total: 1)
    login(@admin)

    close_match_record

    assert_response :success
    assert_not suspension.reload.active?
    license = @player.reload.licenses.first
    assert_equal License::APPROVED, LicenseEffectiveStatus.current_status_id(license)
  end

  test 'eine Datumssperre bleibt vom Spielbericht unberührt' do
    suspension = @player.suspend!(user_id: @admin.id, team_id: @home.id,
                                  valid_until: Date.current + 30)
    login(@admin)

    close_match_record

    assert_response :success
    assert_equal 0, suspension.reload.games_served
    assert suspension.active?
  end

  test 'ein erneut abgeschlossener Bericht zählt nicht doppelt' do
    suspension = @player.suspend!(user_id: @admin.id, team_id: @home.id, games_total: 3)
    login(@admin)

    close_match_record
    assert_response :success
    close_match_record
    assert_response :success

    assert_equal 1, suspension.reload.games_served
  end

  test 'ohne lesbares Spieldatum zählt das Spiel nicht' do
    # Sichere Richtung: `game_days.date` ist eine Zeichenkette, und ohne
    # verwertbares Datum ist nicht feststellbar, ob das Spiel in die Sperre fiel.
    @game_day.update_columns(date: 'Nachholtermin')
    suspension = @player.suspend!(user_id: @admin.id, team_id: @home.id, games_total: 2)
    login(@admin)

    close_match_record

    assert_response :success
    assert_equal 0, suspension.reload.games_served
  end
end
