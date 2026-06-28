class RefereeAssignment < ApplicationRecord
  belongs_to :game
  belongs_to :referee1, class_name: 'Referee', optional: true
  belongs_to :referee2, class_name: 'Referee', optional: true
  # Optionaler Schiedsrichtercoach (Beobachter), immer selbst auch Schiedsrichter.
  belongs_to :coach, class_name: 'Referee', optional: true
  # Alternativ zur Personen-Ansetzung kann ein Verein angesetzt werden, der die
  # Schiedsrichter selbst stellt (entweder/oder – siehe Validierung).
  belongs_to :club, optional: true

  validates :status, inclusion: { in: %w[tentative published] }
  validate :club_or_referees_exclusive

  scope :tentative, -> { where(status: 'tentative') }
  scope :published, -> { where(status: 'published') }

  def referees
    [referee1, referee2].compact
  end

  # True, wenn die Ansetzung über einen Verein (statt zwei Schiris) erfolgt.
  def club_assignment?
    club_id.present?
  end

  private

  # Verein UND Schiris gleichzeitig sind nicht zulässig: entweder ein Verein
  # stellt die Schiris, oder es werden konkrete Personen angesetzt. Der Coach
  # ist in beiden Fällen erlaubt.
  def club_or_referees_exclusive
    return if club_id.blank?
    return if referee1_id.blank? && referee2_id.blank?

    errors.add(:base, 'Entweder ein Verein ODER zwei Schiedsrichter ansetzen, nicht beides.')
  end
end
