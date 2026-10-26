# Eine Regel für den Lizenzvorschlag bei Kursen im System (api#861), gepflegt
# von Admin. Ausgewertet von RefereeLicenseSuggestion: je Kurstyp nach
# `position`, die erste passende gewinnt.
#
# Die Bedingung zählt Spiele laut Spielbericht in der maßgeblichen Saison
# (RefereeLicenseSuggestion.reference_season_id), wahlweise nur Klein- oder
# Großfeld und nur in den gewählten Altersklassen. Ohne `min_games` gilt die
# Regel immer und dient als Rückfall (F-Kurs → L2).
class RefereeLicenseSuggestionRule < ApplicationRecord
  FIELD_SIZES = %w[all KF GF].freeze

  belongs_to :referee_license_level

  validates :course_type, inclusion: { in: RefereeCourse::COURSE_TYPES }
  validates :field_size, inclusion: { in: FIELD_SIZES }
  validates :min_games, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :position, numericality: { only_integer: true }

  scope :ordered, -> { order(:course_type, :position, :id) }

  def age_groups=(value)
    super(Array(value).map(&:to_s).map(&:strip).compact_blank.uniq)
  end
end
