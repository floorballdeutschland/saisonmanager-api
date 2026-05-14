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
end
