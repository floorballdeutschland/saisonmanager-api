class RefereeOnlineTestsController < ApplicationController
  before_action :authenticate_user
  before_action :set_referee
  before_action :set_test, only: %i[show start submit]

  # GET /api/v2/referee/online_tests
  def index
    assignments = OnlineTestAssignment.where(referee: @referee).includes(:online_test)
    test_ids = assignments.map { |a| a.online_test_id }
    attempts_by_test = OnlineTestAttempt.where(referee: @referee, online_test_id: test_ids)
                                        .group_by(&:online_test_id)
    render json: assignments.map { |a| test_list_item(a.online_test, attempts_by_test[a.online_test_id] || []) }
  end

  # GET /api/v2/referee/online_tests/:id
  def show
    attempts = OnlineTestAttempt.where(online_test: @test, referee: @referee)
                                .order(:attempt_number)
    in_progress = attempts.find { |a| a.status == 'in_progress' }

    render json: {
      test: test_detail(@test),
      attempts: attempts.map { |a| attempt_stub(a) },
      in_progress_attempt_id: in_progress&.id,
      can_start: can_start?(@test, attempts),
      results_visible: results_visible?(@test),
      questions: in_progress ? @test.questions.order(:position).map(&:to_exam_hash) : nil
    }
  end

  # POST /api/v2/referee/online_tests/:id/start
  def start
    attempts = OnlineTestAttempt.where(online_test: @test, referee: @referee)
    in_progress = attempts.find { |a| a.status == 'in_progress' }
    return render json: in_progress_response(in_progress), status: :ok if in_progress

    unless can_start?(@test, attempts)
      return render json: { error: 'Keine weiteren Versuche möglich' }, status: :unprocessable_entity
    end

    attempt = OnlineTestAttempt.create!(
      online_test: @test,
      referee: @referee,
      attempt_number: attempts.size + 1,
      status: 'in_progress',
      answers: [],
      started_at: Time.current
    )

    render json: in_progress_response(attempt), status: :created
  rescue ActiveRecord::RecordNotUnique
    in_progress = OnlineTestAttempt.find_by(online_test: @test, referee: @referee, status: 'in_progress')
    return render json: in_progress_response(in_progress), status: :ok if in_progress

    render json: { error: 'Kein Versuch möglich' }, status: :unprocessable_entity
  end

  # POST /api/v2/referee/online_tests/:id/submit
  def submit
    attempt = OnlineTestAttempt.find_by(
      online_test: @test,
      referee: @referee,
      status: 'in_progress'
    )
    return render json: { error: 'Kein aktiver Versuch gefunden' }, status: :not_found unless attempt

    raw_answers = params[:answers]
    unless raw_answers.is_a?(Array)
      return render json: { error: 'Ungültiges Format für answers' }, status: :unprocessable_entity
    end

    valid_question_ids = @test.questions.pluck(:id)
    answers = raw_answers.select { |a| valid_question_ids.include?(a['question_id'].to_i) }

    attempt.update!(answers: answers)
    attempt.calculate_and_set_error_points!

    render json: {
      attempt_id: attempt.id,
      error_points: attempt.error_points,
      passed: attempt.passed?
    }
  end

  private

  def set_referee
    @referee = current_user.referee
    render json: { error: 'Kein Schiedsrichterprofil gefunden' }, status: :forbidden unless @referee
  end

  def set_test
    assignment = OnlineTestAssignment.find_by(online_test_id: params[:id], referee: @referee)
    return render json: { error: 'Prüfung nicht gefunden' }, status: :not_found unless assignment

    @test = assignment.online_test
    return render json: { error: 'Prüfung noch nicht veröffentlicht' }, status: :forbidden unless @test.published?
  end

  def can_start?(test, attempts)
    return false if test.phase_ended?

    completed = attempts.count { |a| a.status == 'completed' }
    in_progress = attempts.any? { |a| a.status == 'in_progress' }
    !in_progress && completed < test.max_attempts
  end

  def results_visible?(test)
    test.phase_ended?
  end

  def test_detail(test)
    {
      id: test.id,
      name: test.name,
      lizenzstufe: test.lizenzstufe,
      time_limit_minutes: test.time_limit_minutes,
      max_attempts: test.max_attempts,
      deadline: test.deadline&.iso8601,
      penalty_options: OnlineTest::PENALTY_OPTIONS
    }
  end

  def test_list_item(test, attempts)
    completed = attempts.select { |a| a.status == 'completed' }
    best = completed.min_by { |a| a.error_points || Float::INFINITY }

    {
      id: test.id,
      name: test.name,
      lizenzstufe: test.lizenzstufe,
      deadline: test.deadline&.iso8601,
      time_limit_minutes: test.time_limit_minutes,
      max_attempts: test.max_attempts,
      attempt_count: completed.size,
      has_in_progress: attempts.any? { |a| a.status == 'in_progress' },
      best_error_points: results_visible?(test) ? best&.error_points : nil,
      passed: results_visible?(test) ? best&.passed? : nil
    }
  end

  def attempt_stub(attempt)
    {
      id: attempt.id,
      attempt_number: attempt.attempt_number,
      status: attempt.status,
      started_at: attempt.started_at.iso8601,
      completed_at: attempt.completed_at&.iso8601,
      error_points: results_visible?(@test) ? attempt.error_points : nil,
      passed: results_visible?(@test) ? attempt.passed? : nil
    }
  end

  def in_progress_response(attempt)
    {
      attempt_id: attempt.id,
      attempt_number: attempt.attempt_number,
      started_at: attempt.started_at.iso8601,
      answers: attempt.answers,
      questions: @test.questions.order(:position).map(&:to_exam_hash),
      time_limit_minutes: @test.time_limit_minutes
    }
  end
end
