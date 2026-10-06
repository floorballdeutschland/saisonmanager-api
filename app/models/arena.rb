class Arena < ApplicationRecord
  has_many :game_days

  scope :active, -> { where(active: true) }

  validates :name, presence: true
  validates :city, presence: true

  def address
    if street.present? || city.present?
      "#{street} #{housenumber}, #{postcode} #{city}"
    else
      self[:address]
    end
  end

  def schedule_item
    if city.present?
      "#{city}, #{name}"
    else
      self[:schedule_item]
    end
  end

  def full_hash
    attributes.merge('schedule_item' => schedule_item)
  end

  # Legt diesen (doppelten) Spielort mit `master` zusammen: hängt alle Spieltage
  # auf den verbleibenden Spielort um und löscht anschließend diesen Eintrag.
  # Gibt die Anzahl der umgehängten Spieltage zurück.
  def merge_into!(master, user_id = nil)
    raise ArgumentError, 'Quell- und Ziel-Spielort dürfen nicht identisch sein' if id == master.id

    moved = 0
    Arena.transaction do
      # Label vor destroy! festhalten. Gleichnamige Spielorte unterscheiden sich
      # oft nur in der Adresse, deshalb steht sie mit im Label.
      MergeLog.record!(
        object_type: 'arena',
        master_id: master.id, master_label: master.merge_label,
        merged_id: id, merged_label: merge_label,
        user_id: user_id
      )
      moved = GameDay.where(arena_id: id).update_all(arena_id: master.id)
      # Der verbleibende Spielort ist der kanonische Eintrag und muss auswählbar
      # sein. Sonst endet der naheliegende Aufräumweg (neu angelegten Spielort in
      # den alten Eintrag mit der Spieltagshistorie zusammenführen) wieder bei
      # einem Spielort, der im Spielplan fehlt (#449).
      # update_columns, weil Altdatensätze ohne Ort die eigene city-Validierung
      # reißen würden und der Merge daran scheitern würde.
      master.update_columns(active: true, updated_at: Time.current) unless master.active?
      destroy!
    end
    moved
  end

  def merge_label
    street_part = [street, housenumber].compact_blank.join(' ')
    place_part = [postcode, city].compact_blank.join(' ')
    location = [street_part, place_part].compact_blank.join(', ')
    location.present? ? "#{name} (#{location})" : name
  end
end
