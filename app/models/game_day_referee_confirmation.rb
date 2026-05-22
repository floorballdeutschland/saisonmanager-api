class GameDayRefereeConfirmation < ApplicationRecord
  belongs_to :game_day
  belongs_to :referee
end
