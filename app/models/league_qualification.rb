class LeagueQualification < ApplicationRecord
  TYPES = %w[promotion playoff playdown relegation championship cup].freeze

  belongs_to :source_league, class_name: 'League'
  belongs_to :target_league, class_name: 'League', optional: true

  validates :rank_from, :rank_to, :qualification_type, presence: true
  validates :rank_from, numericality: { only_integer: true, greater_than: 0 }
  validates :rank_to, numericality: { only_integer: true, greater_than_or_equal_to: :rank_from }
  validates :qualification_type, inclusion: { in: TYPES }
  validate :ranges_do_not_overlap

  private

  def ranges_do_not_overlap
    overlapping = LeagueQualification
      .where(source_league_id:)
      .where.not(id:)
      .where('rank_from <= ? AND rank_to >= ?', rank_to, rank_from)
    errors.add(:base, 'Platzbereiche dürfen sich nicht überschneiden') if overlapping.exists?
  end
end
