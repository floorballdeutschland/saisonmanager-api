class Referee < ApplicationRecord
  belongs_to :game_operation, optional: true

  validates :lizenznummer, presence: true, uniqueness: true, numericality: { only_integer: true, greater_than: 0 }
  validates :vorname, presence: true
  validates :nachname, presence: true

  scope :active, -> { where('gueltigkeit >= ?', Date.today) }
  scope :by_landesverband, ->(lv) { where(landesverband: lv) }
  scope :by_lizenzstufe, ->(stufe) { where(lizenzstufe: stufe) }
  scope :search, ->(q) { where('LOWER(vorname) LIKE :q OR LOWER(nachname) LIKE :q OR lizenznummer::text LIKE :q', q: "%#{q.downcase}%") }

  def games(season_id: nil)
    license_prefix = "#{lizenznummer} %"
    scope = Game.where(
      '? = ANY(referee_ids) OR referee1_string LIKE ? OR referee2_string LIKE ?',
      lizenznummer, license_prefix, license_prefix
    )
    scope = scope.where(season_id: season_id) if season_id
    scope
  end

  def self.incorrect_assignments(season_id: nil)
    scope = Game.where.not(referee1_string: [nil, '']).or(Game.where.not(referee2_string: [nil, '']))
    scope = scope.where(season_id: season_id) if season_id

    known_ids = pluck(:lizenznummer).to_set

    # Process in batches to avoid loading all games into memory at once
    results = []
    scope.in_batches(of: 500) do |batch|
      batch.each do |game|
        unknown = [game.referee1_string, game.referee2_string].any? do |ref_string|
          next false if ref_string.blank?

          match = ref_string.match(/\A(\d+)\s/)
          match && !known_ids.include?(match[1].to_i)
        end
        results << game if unknown
      end
    end
    results
  end
end
