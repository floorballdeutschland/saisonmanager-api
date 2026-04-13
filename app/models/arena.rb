class Arena < ApplicationRecord
  has_many :game_days

  scope :active, -> { where(disabled: false) }

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
    attributes
  end
end
