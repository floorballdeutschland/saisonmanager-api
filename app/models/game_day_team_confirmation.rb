class GameDayTeamConfirmation < ApplicationRecord
  belongs_to :game_day
  belongs_to :team
end
