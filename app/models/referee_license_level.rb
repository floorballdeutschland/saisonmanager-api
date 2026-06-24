class RefereeLicenseLevel < ApplicationRecord
  # Gültigkeitsanker: Lizenzen laufen stets zum 30.09. aus.
  GUELTIGKEIT_ANCHOR_MONTH = 9
  GUELTIGKEIT_ANCHOR_DAY = 30
  DEFAULT_VALIDITY_YEARS = 2

  validates :name, presence: true, uniqueness: true
  validates :validity_years, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  scope :ordered, -> { order(:position, :name) }

  def usage_count
    Referee.where(lizenzstufe: name).count
  end

  # Gültigkeitsdatum für eine Lizenzstufe: 30.09. von (Jahr des Ausstellungs-
  # datums + Gültigkeitsdauer der Stufe). nil ohne Ausstellungsdatum; unbekannte
  # Stufe → Default-Dauer.
  def self.gueltigkeit_for(level_name, reference_date)
    return nil if reference_date.blank?

    years = find_by(name: level_name)&.validity_years || DEFAULT_VALIDITY_YEARS
    Date.new(reference_date.year + years, GUELTIGKEIT_ANCHOR_MONTH, GUELTIGKEIT_ANCHOR_DAY)
  end
end
