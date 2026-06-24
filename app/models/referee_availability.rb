class RefereeAvailability < ApplicationRecord
  belongs_to :referee

  validates :date, presence: true
  validates :date, uniqueness: { scope: :referee_id }
  validate :date_not_in_past

  private

  # Verfügbarkeiten dürfen ab heute (inkl. heutigem Tag) eingetragen werden,
  # nicht für vergangene Tage.
  def date_not_in_past
    return unless date.present?

    errors.add(:date, 'darf nicht in der Vergangenheit liegen') if date < Date.today
  end
end
