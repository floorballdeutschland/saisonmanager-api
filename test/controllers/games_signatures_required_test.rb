require 'test_helper'

# Der Verein kann den Spielbericht erst abschließen, wenn alle Unterschriften
# abgehakt sind. Nach dem Abschluss zeigt die Maske die Haken nicht mehr, und
# der Verein darf den Bericht nicht selbst wieder öffnen: Ein vergessener Haken
# war bis dahin nicht mehr nachzuholen. Die SBK bleibt der Ausweg für eine
# Unterschrift, die es wirklich nicht gibt, sie kontrolliert direkt ab.
class GamesSignaturesRequiredTest < ActionDispatch::IntegrationTest
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
                         game_status: 'aftergame',
                         referee1_string: '12345 Eree, Ref', referee2_string: '23456 Zwei, Ref')
    @vm = create(:user, :vm, club_id: @club.id)
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end

  def change_status(status)
    post "/api/v2/user/games/#{@game.id}/game_status", params: { game_status: status }, as: :json
  end

  test 'ohne alle Unterschriften lehnt der Abschluss ab und nennt die fehlenden' do
    @game.update!(**all_signatures, home_captain_signed: false, referee2_signed: false)
    login(@vm)

    change_status('match_record_closed')

    assert_response :unprocessable_entity
    message = response.parsed_body['message']
    assert_includes message, 'Heim'
    assert_includes message, 'Schiedsrichter 2'
    assert_not_includes message, 'Zeitnehmer/in'
    assert_equal 'aftergame', @game.reload.game_status
  end

  test 'mit allen Unterschriften wird der Bericht abgeschlossen' do
    @game.update!(**all_signatures)
    login(@vm)

    change_status('match_record_closed')

    assert_response :success
    assert_equal 'match_record_closed', @game.reload.game_status
  end

  test 'ein Einzelschiedsrichter braucht keine zweite Unterschrift' do
    @game.update!(**all_signatures, referee2_signed: false, referee2_string: '')
    login(@vm)

    change_status('match_record_closed')

    assert_response :success
    assert_equal 'match_record_closed', @game.reload.game_status
  end

  test 'ein Forfait-Spiel braucht keine Unterschriften' do
    @game.update!(forfait: 1)
    login(@vm)

    change_status('match_record_closed')

    assert_response :success
    assert_equal 'match_record_closed', @game.reload.game_status
  end

  test 'die Zusatzfelder nennen die fehlenden Unterschriften nach derselben Regel' do
    @game.update!(**all_signatures, guest_captain_signed: false, referee2_string: '', referee2_signed: false)
    login(@vm)

    get "/api/v2/user/games/#{@game.id}/additional_fields"

    assert_response :success
    assert_equal ['guest_captain_signed'], response.parsed_body['missing_signatures']
  end

  test 'die SBK kann ohne Unterschriften direkt kontrolliert abschließen' do
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))

    change_status('finalized')

    assert_response :success
    assert_equal 'finalized', @game.reload.game_status
  end
end
