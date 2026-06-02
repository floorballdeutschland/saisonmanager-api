class RefereeBlockedDate < ApplicationRecord
  belongs_to :referee

  validates :date, presence: true
  validates :date, uniqueness: { scope: :referee_id }
  validate :date_must_be_future
  validate :no_tentative_assignment

  private

  def date_must_be_future
    return unless date.present?
    errors.add(:date, 'muss in der Zukunft liegen') if date <= Date.today
  end

  def no_tentative_assignment
    return unless date.present? && referee.present?
    conflict = RefereeAssignment.where(status: %w[tentative published])
                                .where(
                                  '(referee1_id = :id OR referee2_id = :id)',
                                  id: referee.id
                                )
                                .joins(game: :game_day)
                                .where("TO_DATE(game_days.date, 'YYYY-MM-DD') = ?", date)
                                .exists?
    errors.add(:date, 'du bist an diesem Termin bereits eingeplant') if conflict
  end
end
