class Arena < ApplicationRecord
  has_many :game_days

  scope :active, -> { where(disabled: false) }

  def address
    "#{street} #{housenumber}, #{postcode} #{city}"
  end

  def schedule_item
    "#{city}, #{name}"
  end

  def full_hash
    attributes
  end
end
