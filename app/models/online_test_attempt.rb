class OnlineTestAttempt < ApplicationRecord
  belongs_to :online_test
  belongs_to :referee

  validates :attempt_number, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: %w[in_progress completed] }
  validates :referee_id, uniqueness: { scope: %i[online_test_id attempt_number] }

  def completed?
    status == 'completed'
  end

  def passed?
    return nil unless completed? && online_test.pass_threshold_points.present? && error_points.present?

    error_points <= online_test.pass_threshold_points
  end

  def calculate_and_set_error_points!
    questions = online_test.questions.to_a
    points = questions.sum do |question|
      answer = answers.find { |a| a['question_id'] == question.id }
      submitted_rows = answer&.fetch('rows', []) || []

      question.solution.count do |solution_row|
        selected = submitted_rows.find { |r| r['id'] == solution_row['id'] }&.dig('selected')
        selected != solution_row['value']
      end
    end
    update!(error_points: points, status: 'completed', completed_at: Time.current)
  end

  def to_hash(include_answers: false)
    h = {
      id:,
      online_test_id:,
      referee_id:,
      attempt_number:,
      status:,
      error_points:,
      passed: passed?,
      started_at: started_at.iso8601,
      completed_at: completed_at&.iso8601
    }
    h[:answers] = answers if include_answers
    h
  end
end
