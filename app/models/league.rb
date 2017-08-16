class League < ApplicationRecord
  has_many :game_days

  def games
    game_days.map(&:games).flatten
  end

  def league_category
    'league_category'
  end
  
  def league_class
    'league_class'
  end

  def league_system
    'league_system'
  end
end
