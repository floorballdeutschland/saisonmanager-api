class GameDay < ApplicationRecord
  has_many :games
  belongs_to :league
  belongs_to :arena
  belongs_to :club

  # 14
  scope :past_games, -> { where("TO_DATE(date, 'YYYY-MM-DD') > (now()::date - interval '14 days') AND TO_DATE(date, 'YYYY-MM-DD') <= (now()::date + interval '100 days') ") }

  def hosting_club
    club.name if club.present?
  end


end
