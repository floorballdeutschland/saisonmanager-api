require 'test_helper'

class RefereeFeedbackSummariesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @referee = create(:referee)
    @user = User.create!(
      user_name: "sr_#{SecureRandom.hex(4)}",
      password: 'password123', password_confirmation: 'password123',
      permissions: [{ 'user_group_id' => 6, 'game_operation_id' => 0 }],
      teams: [], referee: @referee
    )
  end

  test 'unter fuenf Rueckmeldungen nur die Anzahl, keine Mittelwerte' do
    4.times { create(:referee_feedback, referee1_id: @referee.id, line_rating: 2) }

    login(@user)
    get '/api/v2/referee/feedback_summary'

    assert_response :success
    body = response.parsed_body
    assert_equal 4, body['count']
    assert_equal 5, body['min_count']
    assert_nil body['avg_line_rating']
    assert_nil body['avg_communication_rating']
  end

  test 'ab fuenf Rueckmeldungen die Mittelwerte, egal auf welcher Position' do
    3.times { create(:referee_feedback, referee1_id: @referee.id, line_rating: 6, communication_rating: 9) }
    2.times { create(:referee_feedback, referee2_id: @referee.id, line_rating: 9, communication_rating: 4) }

    login(@user)
    get '/api/v2/referee/feedback_summary'

    body = response.parsed_body
    assert_equal 5, body['count']
    assert_in_delta 7.2, body['avg_line_rating']
    assert_in_delta 7.0, body['avg_communication_rating']
  end

  test 'ausgeblendete und fremde Rueckmeldungen zaehlen nicht, Einzelheiten fehlen' do
    5.times { create(:referee_feedback, referee1_id: @referee.id, general_comment: 'Geheim') }
    create(:referee_feedback, referee1_id: @referee.id, status: 'hidden', line_rating: 1)
    create(:referee_feedback, referee1_id: create(:referee).id, line_rating: 1)

    login(@user)
    get '/api/v2/referee/feedback_summary'

    body = response.parsed_body
    assert_equal 5, body['count']
    assert_in_delta 7.0, body['avg_line_rating']
    assert_equal %w[avg_communication_rating avg_line_rating count min_count], body.keys.sort
    assert_not_includes response.body, 'Geheim'
  end

  test 'ausgeblendete Rueckmeldungen heben nicht ueber die Schwelle' do
    4.times { create(:referee_feedback, referee1_id: @referee.id) }
    create(:referee_feedback, referee1_id: @referee.id, status: 'hidden')

    login(@user)
    get '/api/v2/referee/feedback_summary'

    body = response.parsed_body
    assert_equal 4, body['count']
    assert_nil body['avg_line_rating']
    assert_nil body['avg_communication_rating']
  end

  test 'ohne Anmeldung kein Zugriff' do
    get '/api/v2/referee/feedback_summary'
    assert_response :unauthorized
  end

  test 'Konto ohne Schiedsrichterprofil wird abgewiesen' do
    login(create(:user))
    get '/api/v2/referee/feedback_summary'
    assert_response :forbidden
  end

  private

  def login(user)
    post '/api/v2/login', params: { username: user.user_name, password: 'password123' }
    assert_response :success
  end
end
