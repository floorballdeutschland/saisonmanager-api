# Manuell gepflegte Themen-Taxonomie zur Auswertung des Schiri-Feedbacks (#182),
# z. B. „Positionierung", „Regelauslegung", „Auftreten", „Konfliktkommunikation".
# Bewusst eine flache, FD-weite Liste: Feedback ist ohnehin nur für Admin und die
# globalen FD-Rollen sichtbar, daher kein Verbands-Scoping wie bei RefereeTag.
class FeedbackTheme < ApplicationRecord
  has_many :feedback_theme_taggings, dependent: :destroy
  has_many :referee_feedbacks, through: :feedback_theme_taggings

  validates :name, presence: true,
                   length: { maximum: 40 },
                   uniqueness: { case_sensitive: false }

  scope :ordered, -> { order(Arel.sql('position ASC NULLS LAST'), :name) }
end
