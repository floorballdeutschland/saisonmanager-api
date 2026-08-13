require 'test_helper'

# Verbandsoption „Standardmäßig durch Ansetzer*in" beim Anlegen eines Spiels über
# die Spielplanverwaltung (#403).
class GamePersonLevelDefaultControllerTest < ActionDispatch::IntegrationTest
  setup do
    create(:setting)
    @sa = create(:state_association, referee_assignment_enabled: true,
                                     person_level_assignment_default: true)
    @go = create(:game_operation, state_association_id: @sa.id)
    @league = create(:league, game_operation: @go)
    @game_day = create(:game_day, league: @league, date: (Date.today + 7).to_s)
    login(create(:user, :sbk_scoped, game_operation_id: @go.id))
  end

  test 'neues Spiel wird bei aktiver Voreinstellung markiert' do
    post '/api/v2/games', params: { game: { game_day_id: @game_day.id, game_number: '1' } }

    assert_response :created
    assert Game.last.person_level_assignment
  end

  test 'ohne Voreinstellung bleibt das neue Spiel unmarkiert' do
    @sa.update!(person_level_assignment_default: false)

    post '/api/v2/games', params: { game: { game_day_id: @game_day.id, game_number: '2' } }

    assert_response :created
    assert_not Game.last.person_level_assignment
  end

  # Die Voreinstellung darf eine ausdrückliche Angabe der Maske nicht überstimmen,
  # sonst ließe sich ein Spiel beim Anlegen nicht von der Personenebene ausnehmen.
  test 'ausdrueckliche Angabe schlaegt die Voreinstellung' do
    post '/api/v2/games',
         params: { game: { game_day_id: @game_day.id, game_number: '3', person_level_assignment: false } }

    assert_response :created
    assert_not Game.last.person_level_assignment
  end

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
