class OnlineTest < ApplicationRecord
  has_many :questions, class_name: 'OnlineTestQuestion', dependent: :destroy
  has_many :assignments, class_name: 'OnlineTestAssignment', dependent: :destroy
  has_many :assigned_referees, through: :assignments, source: :referee
  has_many :attempts, class_name: 'OnlineTestAttempt', dependent: :destroy

  validates :name, presence: true
  validates :status, inclusion: { in: %w[draft published] }
  validates :max_attempts, numericality: { only_integer: true, greater_than: 0 }

  default_scope { order(created_at: :desc) }

  PENALTY_OPTIONS = %w[2 2+2 TMS MS FreischlagA FreischlagB Weiterspielen Bully].freeze

  def published?
    status == 'published'
  end

  def phase_ended?
    deadline.present? && deadline < Time.current
  end

  def summary_hash
    {
      id:,
      name:,
      lizenzstufe:,
      time_limit_minutes:,
      max_attempts:,
      pass_threshold_points:,
      deadline: deadline&.iso8601,
      status:,
      question_count: questions.size
    }
  end

  def full_hash
    summary_hash.merge(
      questions: questions.order(:position).map(&:to_hash)
    )
  end
end
