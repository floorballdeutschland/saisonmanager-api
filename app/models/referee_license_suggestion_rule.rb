# Eine Regel für den Lizenzvorschlag bei Kursen im System (api#861): Diese
# Lizenzstufe wird nach einem Kurs dieses Typs vorgeschlagen, wenn die
# Bedingung erfüllt ist. Gepflegt von Admin in der Maske der Lizenzstufen,
# ausgewertet von RefereeLicenseSuggestion.
#
# Die Bedingung zählt Spiele laut Spielbericht in der maßgeblichen Saison
# (RefereeLicenseSuggestion.reference_season_id), wahlweise nur Klein- oder
# Großfeld und nur in den gewählten Altersklassen. Ohne `min_games` gilt die
# Regel immer und dient als Rückfall (F-Kurs → L2).
#
# Eine Regel mit Mindestzahl braucht mindestens eine Altersklasse: Eine leere
# Auswahl hieße, dass kein Spiel zählt, die Regel also nie greift. „Alle"
# bedeutet alle anhaken (Entscheidung 26.10.2026). Für die Rückfallregel ohne
# Mindestzahl spielt die Auswahl keine Rolle und darf leer sein.
class RefereeLicenseSuggestionRule < ApplicationRecord
  FIELD_SIZES = %w[all KF GF].freeze

  belongs_to :referee_license_level

  validates :course_type, inclusion: { in: RefereeCourse::COURSE_TYPES }
  validates :field_size, inclusion: { in: FIELD_SIZES }
  validates :min_games, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :age_groups_present_with_condition

  scope :ordered, -> { order(:course_type, :id) }

  def age_groups=(value)
    super(Array(value).map(&:to_s).map(&:strip).compact_blank.uniq)
  end

  private

  def age_groups_present_with_condition
    return if min_games.nil? || age_groups.present?

    errors.add(:base, 'Bitte mindestens eine Altersklasse auswählen, sonst zählt kein Spiel für die Mindestzahl.')
  end
end
