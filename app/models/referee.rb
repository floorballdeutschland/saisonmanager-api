class Referee < ApplicationRecord
  belongs_to :game_operation, optional: true
  belongs_to :club, optional: true
  has_one :user
  has_many :referee_availabilities, dependent: :destroy
  has_many :referee_qualifications, dependent: :destroy
  has_many :referee_taggings, dependent: :destroy
  has_many :game_day_referee_confirmations, dependent: :destroy
  has_many :referee_qualification_types, through: :referee_qualifications
  has_many :referee_tags, through: :referee_taggings

  validates :lizenznummer,
            uniqueness: { allow_nil: true },
            numericality: { only_integer: true, greater_than: 0, allow_nil: true }
  validates :lizenznummer, presence: true, unless: :guest?
  validates :vorname, presence: true
  validates :nachname, presence: true
  validates :partner_lizenznummer,
            numericality: { only_integer: true, greater_than: 0, allow_nil: true }

  after_save :sync_partner_lizenznummer, if: :saved_change_to_partner_lizenznummer?

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
    tokens = q.to_s.strip.split(/\s+/).reject(&:empty?).first(5)
    return none if tokens.empty?

    # Reine Zahl → exakte Lizenznummer-Suche
    return where(lizenznummer: tokens[0].to_i) if tokens.size == 1 && tokens[0].match?(/\A\d+\z/)

    # Jeder Token muss in vorname, nachname oder lizenznummer vorkommen –
    # dadurch matchen Multi-Wort-Queries wie "Max Müller" auch, wenn Vor-
    # und Nachname in separaten Spalten stehen.
    relation = all
    tokens.each do |t|
      like = "%#{t.downcase}%"
      relation = relation.where(
        'LOWER(vorname) LIKE :t OR LOWER(nachname) LIKE :t OR lizenznummer::text LIKE :t',
        t: like
      )
    end
    relation
  }

  # Spiele dieses Schiris. Kanonisch über die stabile Referee-PK in
  # officiating_referee_ids (Fundament #45), sodass auch Gäste (ohne Lizenznummer)
  # und nach einem Merge verschobene Lizenzen stabil zugeordnet bleiben.
  # referee_ids (Lizenznummer) und die Bericht-Strings dienen als Übergangs-
  # Fallback, bis der Backfill (rake referees:backfill_officiating_ids) alle
  # Alt-Spiele rückbefüllt hat.
  def games(season_id: nil)
    conditions = ['? = ANY(officiating_referee_ids)']
    values = [id]

    if lizenznummer.present?
      license_prefix = "#{lizenznummer} %"
      conditions.push('? = ANY(referee_ids)', 'referee1_string LIKE ?', 'referee2_string LIKE ?')
      values.push(lizenznummer, license_prefix, license_prefix)
    end

    scope = Game.where(conditions.join(' OR '), *values)
    scope = scope.joins(game_day: :league).where(leagues: { season_id: season_id }) if season_id
    scope
  end

  def merge_into!(master, user_id = nil)
    raise ArgumentError, 'Master und Secondary dürfen nicht identisch sein' if id == master.id
    raise ArgumentError, 'Secondary ist bereits zusammengeführt' if merged_into_id.present?
    raise ArgumentError, 'Master ist bereits zusammengeführt' if master.merged_into_id.present?

    merged_label = "#{nachname}, #{vorname}"

    ActiveRecord::Base.transaction do
      scalar_fields = %w[
        vorname nachname geburtsdatum email club_id game_operation_id
        lizenzstufe gueltigkeit strasse hausnummer plz ort
      ]
      scalar_fields.each do |field|
        master[field] = self[field] if master[field].blank? && self[field].present?
      end

      # Falls Master keine Lizenznummer hat, übertrage die der Secondary.
      # Wegen UNIQUE-Index auf lizenznummer muss die Secondary erst geleert werden.
      transferred_lizenznummer = nil
      if master.lizenznummer.blank? && lizenznummer.present?
        transferred_lizenznummer = lizenznummer
        update_columns(lizenznummer: nil)
        master.lizenznummer = transferred_lizenznummer
      end

      master.save!(validate: false)

      existing_qt_ids = master.referee_qualifications.pluck(:referee_qualification_type_id)
      referee_qualifications.where.not(referee_qualification_type_id: existing_qt_ids).update_all(referee_id: master.id)

      existing_tag_ids = master.referee_taggings.pluck(:referee_tag_id)
      referee_taggings.where.not(referee_tag_id: existing_tag_ids).update_all(referee_id: master.id)

      referee_availabilities.update_all(referee_id: master.id)

      if user.present?
        if master.user.nil?
          user.update!(referee_id: master.id)
        else
          user.update!(referee_id: nil)
        end
      end

      _rewrite_referee_game_references(master, secondary_lizenznummer: transferred_lizenznummer || lizenznummer)

      # validate: false – die Secondary kann nach dem Lizenznummern-Transfer
      # die Pflicht-Validierung (Lizenznummer für Nicht-Gäste) nicht mehr erfüllen.
      self.merged_into_id = master.id
      save!(validate: false)

      MergeLog.record!(
        object_type: 'referee',
        master_id: master.id, master_label: "#{master.nachname}, #{master.vorname}",
        merged_id: id, merged_label: merged_label,
        user_id: user_id
      )
    end
  end

  private

  def sync_partner_lizenznummer
    return if partner_lizenznummer.blank? || lizenznummer.blank? || partner_lizenznummer == lizenznummer

    partner = Referee.where(lizenznummer: partner_lizenznummer).where(partner_lizenznummer: nil).first
    partner&.update_column(:partner_lizenznummer, lizenznummer)
  end

  def _rewrite_referee_game_references(master, secondary_lizenznummer: lizenznummer)
    if secondary_lizenznummer.present? && master.lizenznummer.present? &&
       secondary_lizenznummer != master.lizenznummer
      Game.where('? = ANY(referee_ids)', secondary_lizenznummer)
          .update_all("referee_ids = array_replace(referee_ids, #{secondary_lizenznummer.to_i}, #{master.lizenznummer.to_i})")

      Game.where('referee1_string LIKE ?', "#{secondary_lizenznummer} %")
          .update_all("referee1_string = REPLACE(referee1_string, '#{secondary_lizenznummer.to_i} ', '#{master.lizenznummer.to_i} ')")
      Game.where('referee2_string LIKE ?', "#{secondary_lizenznummer} %")
          .update_all("referee2_string = REPLACE(referee2_string, '#{secondary_lizenznummer.to_i} ', '#{master.lizenznummer.to_i} ')")
    end

    return unless id != master.id

    Game.where('? = ANY(nominated_referee_ids)', id)
        .update_all("nominated_referee_ids = array_replace(nominated_referee_ids, #{id.to_i}, #{master.id.to_i})")

    Game.where('? = ANY(officiating_referee_ids)', id)
        .update_all("officiating_referee_ids = array_replace(officiating_referee_ids, #{id.to_i}, #{master.id.to_i})")
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
