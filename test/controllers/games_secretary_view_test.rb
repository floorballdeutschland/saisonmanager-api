require 'test_helper'

# Spielsekretariat per Einmal-Link: kein Benutzerkonto, der Token ist die
# Berechtigung. Bearbeiten durfte es die Spiele seines Spieltags schon
# (SECRETARY_ACTIONS), die Spielseite selbst lieferte ihm aber nichts:
# `show` füllte @secretary_link nie, und `show_hidden` verlangte einen Login.
class GamesSecretaryViewTest < ActionDispatch::IntegrationTest
  API_KEY = 'test-key-for-smoke-tests'.freeze

  setup do
    create(:setting)
    @sa = create(:state_association)
    @sa.checklist_items.create!(question: 'Halle bespielbar?', position: 1)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @club = create(:club, state_association_id: @sa.id)
    @arena = create(:arena)
    @game_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 1, date: '2026-01-10')
    @game = build_game(@game_day)

    # Zweiter Spieltag derselben Liga: außerhalb des Token-Scopes.
    other_day = GameDay.create!(league: @league, arena: @arena, club: @club, number: 2, date: '2026-01-17')
    @foreign_game = build_game(other_day)

    @user = create(:user, :admin)
    _link, @token = GameDaySecretaryLink.generate!(game_days: [@game_day], created_by: @user)
  end

  test 'Spielseite liefert dem Sekretariat die Rechte fuer den Spielbericht' do
    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: @token },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body['permission'], 'edit_game_report'
    assert_includes body['permission'], 'pregame_edit_home'
    # Kontroll- und Ligarechte bleiben aus, auch wenn der Link von einem Admin
    # erzeugt wurde.
    assert_not_includes body['permission'], 'check_game'
    assert_not_includes body['permission'], 'edit_game'
    assert_not_includes body['permission'], 'edit_referee_nomination'
  end

  test 'Spielseite liefert dem Sekretariat die Checkliste' do
    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: @token },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['checklist_active']
    assert_equal(['Halle bespielbar?'], body['checklist_items'].map { |i| i['question'] })
  end

  test 'ein fremder Spieltag gibt dem Sekretariat keine Rechte' do
    get "/api/v2/games/#{@foreign_game.id}.json", params: { secretary_token: @token },
                                                  headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_empty JSON.parse(response.body)['permission']
  end

  test 'Spielseite bleibt ohne Token oeffentlich erreichbar' do
    get "/api/v2/games/#{@game.id}.json", headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_nil JSON.parse(response.body)['permission']
  end

  test 'ein unbrauchbarer Token macht die oeffentliche Spielseite nicht kaputt' do
    get "/api/v2/games/#{@game.id}.json", params: { secretary_token: 'falsch' },
                                          headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_nil JSON.parse(response.body)['permission']
  end

  test 'interne Felder sind fuer das Sekretariat erreichbar' do
    @game.update!(special_event_string: 'Interner Vermerk')

    get "/api/v2/user/games/#{@game.id}/additional_fields.json",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal 'Interner Vermerk', JSON.parse(response.body)['special_event_string']
  end

  test 'interne Felder eines fremden Spieltags bleiben verborgen' do
    @foreign_game.update!(special_event_string: 'Interner Vermerk')

    get "/api/v2/user/games/#{@foreign_game.id}/additional_fields.json",
        params: { secretary_token: @token }, headers: { 'X-Api-Key' => API_KEY }

    assert_response :success
    assert_equal({}, JSON.parse(response.body))
  end

  test 'interne Felder ohne Token und ohne Login bleiben gesperrt' do
    get "/api/v2/user/games/#{@game.id}/additional_fields.json", headers: { 'X-Api-Key' => API_KEY }

    # Vorher lief das in ein NoMethodError auf nil, sobald kein Login vorlag.
    assert_response :unauthorized
  end

  private

  def build_game(game_day)
    Game.create!(
      game_day: game_day,
      home_team: create(:team, league: @league, club: @club),
      guest_team: create(:team, league: @league, club: @club),
      forfait: 0,
      overtime: false,
      legacy: false,
      events: [],
      players: { 'home' => [], 'guest' => [] }
    )
  end
end
