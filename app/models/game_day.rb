class GameDay < ApplicationRecord
  has_many :games
  belongs_to :league
  belongs_to :arena
  belongs_to :club

  def hosting_club
    club.name if club.present?
  end
end
