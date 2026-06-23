class RefereeAvailability < ApplicationRecord
  belongs_to :referee

  validates :date, presence: true
  validates :date, uniqueness: { scope: :referee_id }
  validate :date_must_be_future

  private

  def date_must_be_future
    return unless date.present?

    errors.add(:date, 'muss in der Zukunft liegen') if date <= Date.today
  end
end
