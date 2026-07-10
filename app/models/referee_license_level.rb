class RefereeLicenseLevel < ApplicationRecord
  # Gültigkeitsanker: Lizenzen laufen regulär zum 30.09. aus. In Regeljahren
  # (alle 4 Jahre: 2022, 2026, 2030, …) endet die Gültigkeit bereits am 31.07.
  GUELTIGKEIT_ANCHOR_MONTH = 9
  GUELTIGKEIT_ANCHOR_DAY = 30
  REGELJAHR_ANCHOR_MONTH = 7
  REGELJAHR_ANCHOR_DAY = 31
  DEFAULT_VALIDITY_YEARS = 1

  validates :name, presence: true, uniqueness: true
  validates :validity_years, numericality: { only_integer: true, greater_than_or_equal_to: 1 }

  scope :ordered, -> { order(:position, :name) }

  def usage_count
    Referee.where(lizenzstufe: name).count
  end

  # Regeljahr = alle 4 Jahre ab 2022 (Jahr % 4 == 2).
  def self.regeljahr?(year)
    (year % 4) == 2
  end

  # Stichtag im gegebenen Ablaufjahr: 31.07. im Regeljahr, sonst 30.09.
  def self.anchor_date_for(year)
    if regeljahr?(year)
      Date.new(year, REGELJAHR_ANCHOR_MONTH, REGELJAHR_ANCHOR_DAY)
    else
      Date.new(year, GUELTIGKEIT_ANCHOR_MONTH, GUELTIGKEIT_ANCHOR_DAY)
    end
  end

  # Gültigkeitsdatum für eine Lizenzstufe: Stichtag (31.07./30.09.) im Jahr
  # (Ausstellungsjahr + Gültigkeitsdauer der Stufe). nil ohne Ausstellungs-
  # datum; unbekannte Stufe → Default-Dauer.
  def self.gueltigkeit_for(level_name, reference_date)
    return nil if reference_date.blank?

    years = find_by(name: level_name)&.validity_years || DEFAULT_VALIDITY_YEARS
    anchor_date_for(reference_date.year + years)
  end
end
