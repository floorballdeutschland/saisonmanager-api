class GameDay < ApplicationRecord
  has_many :games
  belongs_to :league
end
