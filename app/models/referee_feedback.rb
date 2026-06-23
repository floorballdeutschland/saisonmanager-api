# Rückmeldung einer am Spiel beteiligten Mannschaft (TM/VM) zum Schiedsrichter-
# gespann eines Spiels. Verpflichtend nach jedem Spiel der dafür freigeschalteten
# Ligen (League#referee_feedback_enabled). Pro Spiel und Team genau eine Abgabe
# (siehe Unique-Index game_id+team_id). Sichtbar ausschließlich in der
# Schiriverwaltung am Schiri-Profil (Admin / RSK-FD / Ansetzer-FD).
class RefereeFeedback < ApplicationRecord
  RATING_RANGE = (1..10)

  belongs_to :game
  belongs_to :team
  belongs_to :referee1, class_name: 'Referee', optional: true
  belongs_to :referee2, class_name: 'Referee', optional: true
  belongs_to :submitted_by, class_name: 'User', foreign_key: :submitted_by_user_id, optional: true

  validates :line_rating, :communication_rating,
            presence: true, inclusion: { in: RATING_RANGE }
  validates :game_id, uniqueness: { scope: :team_id }

  scope :visible, -> { where(status: 'visible') }
  scope :for_referee, lambda { |referee_id|
    where('referee1_id = :id OR referee2_id = :id', id: referee_id)
  }

  def visible?
    status == 'visible'
  end
end
