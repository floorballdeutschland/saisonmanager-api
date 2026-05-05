class RefereeAssignment < ApplicationRecord
  belongs_to :game
  belongs_to :referee1, class_name: 'Referee', optional: true
  belongs_to :referee2, class_name: 'Referee', optional: true

  validates :status, inclusion: { in: %w[tentative published] }

  scope :tentative, -> { where(status: 'tentative') }
  scope :published, -> { where(status: 'published') }

  def referees
    [referee1, referee2].compact
  end
end
