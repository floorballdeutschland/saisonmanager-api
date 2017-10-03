class Arena < ApplicationRecord
  has_many :game_days
  
  def address
    "#{street} #{housenumber}, #{postcode} #{city}"
  end

  def schedule_item
    "#{city}, #{name}"
  end
end
