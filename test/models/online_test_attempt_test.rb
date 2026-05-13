require 'test_helper'

class OnlineTestAttemptTest < ActiveSupport::TestCase
  def build_test_with_questions(questions_data)
    test = OnlineTest.new(
      name: 'Testprüfung',
      status: 'published',
      max_attempts: 2
    )
    questions_data.each_with_index do |qdata, i|
      test.questions.build(
        position: i + 1,
        scenario: "Szenario #{i + 1}",
        rows: qdata[:rows],
        solution: qdata[:solution]
      )
    end
    test.save!
    test
  end

  def build_attempt(test, answers)
    OnlineTestAttempt.create!(
      online_test: test,
      referee: referees(:one),
      attempt_number: 1,
      status: 'in_progress',
      answers: answers,
      started_at: Time.current
    )
  end

  # ---------------------------------------------------------------------------
  # calculate_and_set_error_points!
  # ---------------------------------------------------------------------------

  test 'alle Antworten korrekt ergibt 0 Fehlerpunkte' do
    t = build_test_with_questions([
      {
        rows: [{ 'id' => 1, 'label' => 'Spieler 7' }, { 'id' => 2, 'label' => 'Spieler 10' }],
        solution: [{ 'id' => 1, 'value' => '2' }, { 'id' => 2, 'value' => 'MS' }]
      }
    ])
    q = t.questions.first

    answers = [{ 'question_id' => q.id, 'rows' => [{ 'id' => 1, 'selected' => '2' }, { 'id' => 2, 'selected' => 'MS' }] }]
    attempt = build_attempt(t, answers)
    attempt.calculate_and_set_error_points!

    assert_equal 0, attempt.error_points
    assert_equal 'completed', attempt.status
    assert_not_nil attempt.completed_at
  end

  test 'eine falsche Antwort ergibt 1 Fehlerpunkt' do
    t = build_test_with_questions([
      {
        rows: [{ 'id' => 1, 'label' => 'Spieler 7' }, { 'id' => 2, 'label' => 'Spieler 10' }],
        solution: [{ 'id' => 1, 'value' => '2' }, { 'id' => 2, 'value' => 'MS' }]
      }
    ])
    q = t.questions.first

    answers = [{ 'question_id' => q.id, 'rows' => [{ 'id' => 1, 'selected' => '2' }, { 'id' => 2, 'selected' => 'TMS' }] }]
    attempt = build_attempt(t, answers)
    attempt.calculate_and_set_error_points!

    assert_equal 1, attempt.error_points
  end

  test 'fehlende Row-Antwort zählt als Fehlerpunkt' do
    t = build_test_with_questions([
      {
        rows: [{ 'id' => 1, 'label' => 'Spieler 7' }, { 'id' => 2, 'label' => 'Spieler 10' }],
        solution: [{ 'id' => 1, 'value' => '2' }, { 'id' => 2, 'value' => 'MS' }]
      }
    ])
    q = t.questions.first

    # Row 2 fehlt komplett in der Antwort
    answers = [{ 'question_id' => q.id, 'rows' => [{ 'id' => 1, 'selected' => '2' }] }]
    attempt = build_attempt(t, answers)
    attempt.calculate_and_set_error_points!

    assert_equal 1, attempt.error_points
  end

  test 'leere Antwort ergibt Fehlerpunkte für alle Rows aller Fragen' do
    t = build_test_with_questions([
      {
        rows: [{ 'id' => 1, 'label' => 'A' }, { 'id' => 2, 'label' => 'B' }],
        solution: [{ 'id' => 1, 'value' => '2' }, { 'id' => 2, 'value' => 'MS' }]
      },
      {
        rows: [{ 'id' => 1, 'label' => 'C' }],
        solution: [{ 'id' => 1, 'value' => 'TMS' }]
      }
    ])

    attempt = build_attempt(t, [])
    attempt.calculate_and_set_error_points!

    assert_equal 3, attempt.error_points
  end

  test 'mehrere Fragen werden korrekt summiert' do
    t = build_test_with_questions([
      {
        rows: [{ 'id' => 1, 'label' => 'A' }],
        solution: [{ 'id' => 1, 'value' => '2' }]
      },
      {
        rows: [{ 'id' => 1, 'label' => 'B' }, { 'id' => 2, 'label' => 'C' }],
        solution: [{ 'id' => 1, 'value' => 'MS' }, { 'id' => 2, 'value' => 'TMS' }]
      }
    ])
    questions = t.questions.order(:position).to_a

    answers = [
      { 'question_id' => questions[0].id, 'rows' => [{ 'id' => 1, 'selected' => 'MS' }] }, # falsch
      { 'question_id' => questions[1].id, 'rows' => [{ 'id' => 1, 'selected' => 'MS' }, { 'id' => 2, 'selected' => 'TMS' }] } # beide richtig
    ]
    attempt = build_attempt(t, answers)
    attempt.calculate_and_set_error_points!

    assert_equal 1, attempt.error_points
  end

  # ---------------------------------------------------------------------------
  # passed?
  # ---------------------------------------------------------------------------

  test 'passed? gibt nil zurück wenn kein threshold gesetzt' do
    t = OnlineTest.create!(name: 'T', status: 'published', max_attempts: 2, pass_threshold_points: nil)
    attempt = OnlineTestAttempt.create!(
      online_test: t, referee: referees(:one),
      attempt_number: 1, status: 'completed',
      answers: [], started_at: Time.current, error_points: 0
    )

    assert_nil attempt.passed?
  end

  test 'passed? gibt true zurück wenn Fehlerpunkte <= threshold' do
    t = OnlineTest.create!(name: 'T', status: 'published', max_attempts: 2, pass_threshold_points: 3)
    attempt = OnlineTestAttempt.create!(
      online_test: t, referee: referees(:one),
      attempt_number: 1, status: 'completed',
      answers: [], started_at: Time.current, error_points: 3
    )

    assert attempt.passed?
  end

  test 'passed? gibt false zurück wenn Fehlerpunkte > threshold' do
    t = OnlineTest.create!(name: 'T', status: 'published', max_attempts: 2, pass_threshold_points: 3)
    attempt = OnlineTestAttempt.create!(
      online_test: t, referee: referees(:one),
      attempt_number: 1, status: 'completed',
      answers: [], started_at: Time.current, error_points: 4
    )

    assert_not attempt.passed?
  end

  test 'passed? gibt nil zurück wenn Versuch noch nicht abgeschlossen' do
    t = OnlineTest.create!(name: 'T', status: 'published', max_attempts: 2, pass_threshold_points: 3)
    attempt = OnlineTestAttempt.new(
      online_test: t, referee: referees(:one),
      attempt_number: 1, status: 'in_progress',
      answers: [], started_at: Time.current
    )

    assert_nil attempt.passed?
  end
end
