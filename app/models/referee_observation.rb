# Beobachtungsbogen eines Schiedsrichtercoaches zu einem Spiel. Löst den
# Microsoft-Forms-Bogen „Referee Coaching Form / Beobachtungsformular" ab.
#
# Abgrenzung zum Vereins-Feedback (RefereeFeedback): Dort meldet die Mannschaft
# zurück, der Bogen hängt am Gespann, und die beobachtete Person sieht ihn
# bewusst NICHT. Hier meldet ein qualifizierter Coach zurück, jede Person des
# Gespanns wird einzeln bewertet (referee_observation_ratings), und die
# beobachtete Person sieht den Bogen im eigenen Profil – das ist der Zweck.
#
# Ein Bogen je Spiel und Coach (Unique-Index game_id+coach_id).
class RefereeObservation < ApplicationRecord
  RATING_RANGE = (1..7)

  # Die fünf Bewertungsdimensionen des Formulars (Fragen 10/12/14/16/20). In
  # dieser Reihenfolge stehen sie auch im Bogen; Modell, Controller und Tests
  # leiten ihre Spaltennamen daraus ab, damit eine Dimension nur an einer Stelle
  # benannt ist.
  DIMENSIONS = %i[stick_play physical_play penalty_line game_management overall].freeze
  PAIR_RATING_ATTRIBUTES = DIMENSIONS.map { |d| :"pair_#{d}_rating" }.freeze
  # Freitexte des Bogens (Fragen 5/11/13/15/17/18/19), alle Pflicht wie im Original.
  TEXT_ATTRIBUTES = %i[
    match_description stick_play_comment physical_play_comment penalty_line_comment
    game_management_comment other_matters final_comments
  ].freeze

  belongs_to :game
  belongs_to :coach, class_name: 'Referee'
  belongs_to :referee_assignment, optional: true
  belongs_to :created_by, class_name: 'User', foreign_key: :created_by_user_id, optional: true
  has_many :ratings, class_name: 'RefereeObservationRating', dependent: :destroy

  accepts_nested_attributes_for :ratings

  validates :game_id, uniqueness: { scope: :coach_id }
  validates :game_operation_id, :submitted_at, presence: true
  validates(*PAIR_RATING_ATTRIBUTES, presence: true, inclusion: { in: RATING_RANGE })
  validates(*TEXT_ATTRIBUTES, presence: true)
  validate :must_rate_at_least_one_referee

  scope :visible, -> { where(status: 'visible') }
  scope :for_coach, ->(coach_id) { where(coach_id: coach_id) }
  # Bögen, in denen diese Person bewertet wurde. Über die Kindtabelle, damit die
  # Zuordnung personenscharf bleibt – anders als beim Vereins-Feedback, das an
  # beiden Schiris gleichzeitig hängt.
  scope :for_referee, lambda { |referee_id|
    where(id: RefereeObservationRating.where(referee_id: referee_id).select(:referee_observation_id))
  }

  def visible?
    status == 'visible'
  end

  private

  # Ein Bogen ohne bewertete Person wäre für die beobachteten Schiedsrichter
  # unsichtbar und für die Auswertung wertlos.
  def must_rate_at_least_one_referee
    return if ratings.reject(&:marked_for_destruction?).any?

    errors.add(:ratings, 'Es muss mindestens ein Schiedsrichter bewertet werden.')
  end
end
