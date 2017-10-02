class GameOperation < ApplicationRecord
  has_many :leagues

  def games
    leagues.map(&:games).flatten.sort_by{|i| i.game_number.to_i}
  end
end
