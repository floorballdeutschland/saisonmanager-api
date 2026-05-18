class Referee < ApplicationRecord
  belongs_to :game_operation, optional: true
  belongs_to :club, optional: true
  has_one :user
  has_many :referee_blocked_dates, dependent: :destroy
  has_many :referee_qualifications, dependent: :destroy
  has_many :referee_qualification_types, through: :referee_qualifications

  validates :lizenznummer,
            uniqueness: { allow_nil: true },
            numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :lizenznummer, presence: true, unless: :guest?
  validates :vorname, presence: true
  validates :nachname, presence: true
  validates :partner_lizenznummer,
            numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validate :partner_must_exist, if: -> { partner_lizenznummer.present? }

  def lizenznummer_display
    guest? ? "G-#{id}" : lizenznummer.to_s
  end

  def landesverband
    club&.state_association&.name
  end

  scope :active, -> { where('gueltigkeit >= ?', Date.today).where(merged_into_id: nil) }
  scope :by_landesverband, lambda { |lv|
    joins(club: :state_association).where(state_associations: { name: lv })
  }
  scope :by_lizenzstufe, ->(stufe) { where(lizenzstufe: stufe) }
  scope :search, lambda { |q|
    tokens = q.to_s.downcase.split(/\s+/).reject(&:empty?).first(5)
    return none if tokens.empty?

    # Jeder Token muss in vorname, nachname oder lizenznummer vorkommen –
    # dadurch matchen Multi-Wort-Queries wie "Max Müller" auch, wenn Vor-
    # und Nachname in separaten Spalten stehen.
    relation = all
    tokens.each do |t|
      like = "%#{t}%"
      relation = relation.where(
        'LOWER(vorname) LIKE :t OR LOWER(nachname) LIKE :t OR lizenznummer::text LIKE :t',
        t: like
      )
    end
    relation
  }

  def games(season_id: nil)
    return Game.none if lizenznummer.nil?

    license_prefix = "#{lizenznummer} %"
    scope = Game.where(
      '? = ANY(referee_ids) OR referee1_string LIKE ? OR referee2_string LIKE ?',
      lizenznummer, license_prefix, license_prefix
    )
    if season_id
      scope = scope.joins(game_day: :league).where(leagues: { season_id: season_id })
    end
    scope
  end

  def merge_into!(master)
    raise ArgumentError, 'Master und Secondary dürfen nicht identisch sein' if id == master.id

    scalar_fields = %w[
      vorname nachname geburtsdatum email club_id game_operation_id
      lizenzstufe gueltigkeit strasse hausnummer plz ort
    ]
    scalar_fields.each do |field|
      master[field] = self[field] if master[field].blank? && self[field].present?
    end
    master.save!(validate: false)

    existing_qt_ids = master.referee_qualifications.pluck(:qualification_type_id)
    referee_qualifications.where.not(qualification_type_id: existing_qt_ids).update_all(referee_id: master.id)

    referee_blocked_dates.update_all(referee_id: master.id)

    if user.present?
      if master.user.nil?
        user.update!(referee_id: master.id)
      else
        user.update!(referee_id: nil)
      end
    end

    _rewrite_referee_game_references(master)

    update!(merged_into_id: master.id)
  end

  private

  def partner_must_exist
    errors.add(:partner_lizenznummer, 'nicht gefunden') unless Referee.exists?(lizenznummer: partner_lizenznummer)
  end

  def _rewrite_referee_game_references(master)
    return if lizenznummer.nil?

    if master.lizenznummer.present?
      Game.where('? = ANY(referee_ids)', lizenznummer)
          .update_all("referee_ids = array_replace(referee_ids, #{lizenznummer}, #{master.lizenznummer})")

      Game.where('referee1_string LIKE ?', "#{lizenznummer} %")
          .update_all("referee1_string = REPLACE(referee1_string, '#{lizenznummer} ', '#{master.lizenznummer} ')")
      Game.where('referee2_string LIKE ?', "#{lizenznummer} %")
          .update_all("referee2_string = REPLACE(referee2_string, '#{lizenznummer} ', '#{master.lizenznummer} ')")
    end

    Game.where('? = ANY(nominated_referee_ids)', id)
        .update_all("nominated_referee_ids = array_replace(nominated_referee_ids, #{id}, #{master.id})")
  end

  public

  def self.incorrect_assignments(season_id: nil)
    scope = Game.where.not(referee1_string: [nil, '']).or(Game.where.not(referee2_string: [nil, '']))
    scope = scope.where(season_id: season_id) if season_id

    known_ids = pluck(:lizenznummer).compact.to_set

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
