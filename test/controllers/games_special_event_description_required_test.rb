require 'test_helper'

# Seit 11.11.2026 verlangt ein besonderes Ereignis kein Berichtsformular der
# Schiris mehr. Stattdessen muss es im Spielbericht selbst beschrieben sein:
# Ist der Haken gesetzt, schließt der Bericht erst ab, wenn die Beschreibung
# mindestens Game::SPECIAL_EVENT_DESCRIPTION_MIN_LENGTH Zeichen hat. Wie bei
# den Unterschriften entfällt die Prüfung für die SBK des Spielbetriebs.
class GamesSpecialEventDescriptionRequiredTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting, current_season_id: '18')
    @go = create(:game_operation, state_association_id: create(:state_association).id)
    @league = create(:league, :current_season, game_operation: @go, league_modus: 'league',
                                               age_group: 'Herren', field_size: 'GF')
    @club = create(:club)
    @game_day = GameDay.create!(league: @league, arena: create(:arena), club: @club,
                                number: 1, date: Date.current.to_s)
    @home = create(:team, league: @league, club: @club)
    @guest = create(:team, league: @league, club: create(:club))
    @game = Game.create!(game_day: @game_day, home_team: @home, guest_team: @guest,
                         started: true, ended: true, forfait: 0, overtime: false, legacy: false,
                         events: [], players: { 'home' => [], 'guest' => [] },
                         game_status: 'aftergame', special_event: true, **all_signatures,
                         referee1_string: '12345 Eree, Ref', referee2_string: '23456 Zwei, Ref')
    @vm = create(:user, :vm, club_id: @club.id)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def close_match_record
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: 'match_record_closed' }, as: :json
  end

  test 'ohne Beschreibung lehnt der Abschluss ab' do
    login(@vm)

    close_match_record

    assert_response :unprocessable_entity
    assert_includes response.parsed_body['message'], 'besonderes Ereignis'
    assert_includes response.parsed_body['message'], '50 Zeichen'
    assert_equal 'aftergame', @game.reload.game_status
  end

  test '49 Zeichen reichen nicht, Leerraum am Rand zählt nicht mit' do
    @game.update!(special_event_string: "   #{'x' * 49}   \n")
    login(@vm)

    close_match_record

    assert_response :unprocessable_entity
    assert_equal 'aftergame', @game.reload.game_status
  end

  test 'mit 50 Zeichen wird der Bericht abgeschlossen' do
    @game.update!(special_event_string: 'x' * 50)
    login(@vm)

    close_match_record

    assert_response :success
    assert_equal 'match_record_closed', @game.reload.game_status
  end

  test 'ohne besonderes Ereignis ist keine Beschreibung nötig' do
    @game.update!(special_event: false)
    login(@vm)

    close_match_record

    assert_response :success
    assert_equal 'match_record_closed', @game.reload.game_status
  end

  test 'über den Sekretariats-Link gilt die Pflicht ebenso' do
    _link, token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: create(:user, :admin))

    post "/api/v2/user/games/#{@game.id}/game_status",
         params: { game_status: 'match_record_closed' }, headers: { 'X-Secretary-Token' => token }, as: :json

    assert_response :unprocessable_entity
    assert_equal 'aftergame', @game.reload.game_status
  end

  test 'die SBK des Spielbetriebs schließt auch ohne Beschreibung ab' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    close_match_record

    assert_response :success
    assert_equal 'match_record_closed', @game.reload.game_status
  end
end
