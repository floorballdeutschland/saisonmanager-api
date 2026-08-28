# Personenbezogener Teil eines Beobachtungsbogens: die Zeilen „Referee 1" und
# „Referee 2" der fünf Bewertungsmatrizen. Die Zeile „Pair / Team" steht am
# RefereeObservation selbst, denn das Gespann ist keine Person.
class RefereeObservationRating < ApplicationRecord
  RATING_ATTRIBUTES = RefereeObservation::DIMENSIONS.map { |d| :"#{d}_rating" }.freeze

  belongs_to :referee_observation
  belongs_to :referee

  validates :position, presence: true, inclusion: { in: [1, 2] }
  validates(*RATING_ATTRIBUTES, presence: true,
                                inclusion: { in: RefereeObservation::RATING_RANGE })
  validates :referee_id, uniqueness: { scope: :referee_observation_id }
end
