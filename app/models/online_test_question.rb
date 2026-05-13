class OnlineTestQuestion < ApplicationRecord
  belongs_to :online_test

  validates :scenario, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  default_scope { order(:position, :id) }

  def to_hash
    {
      id:,
      position:,
      scenario:,
      rows:,
      solution:
    }
  end

  def to_exam_hash
    {
      id:,
      position:,
      scenario:,
      rows:
    }
  end
end
