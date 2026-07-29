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
  has_many :feedback_theme_taggings, dependent: :destroy
  has_many :feedback_themes, through: :feedback_theme_taggings

  validates :line_rating, :communication_rating,
            presence: true, inclusion: { in: RATING_RANGE }
  validates :game_id, uniqueness: { scope: :team_id }

  scope :visible, -> { where(status: 'visible') }
  scope :for_referee, lambda { |referee_id|
    where('referee1_id = :id OR referee2_id = :id', id: referee_id)
  }
  # Rückmeldungen mit mindestens einem ausgefüllten Freitextkommentar
  # (Grundlage für den Kommentar-Feed, #182).
  scope :with_comment, lambda {
    where("COALESCE(line_comment, '') <> '' OR COALESCE(communication_comment, '') <> '' " \
          "OR COALESCE(general_comment, '') <> ''")
  }

  def visible?
    status == 'visible'
  end

  # Über welchen Weg die Rückmeldung kam: aus einem angemeldeten Konto (Team- oder
  # Vereinsmanager) oder über einen Einmal-Link ohne Konto (Kapitän*in bzw. der
  # von der Mannschaft hinterlegte Feedback-Kontakt).
  #
  # Bestandsdaten liefern 'account', denn der Abgabeweg per Konto setzt seit der
  # ersten Fassung immer submitted_by_user_id. nil ist nur ein defensiver Rest für
  # Datensätze ohne beides (in der Praxis bisher nicht vorgekommen): Dann wird
  # kein Weg behauptet.
  def submitted_via
    return 'invitation' if submitted_by_email.present? || submitted_by_player_id.present?
    return 'account' if submitted_by_user_id.present?

    nil
  end
end
