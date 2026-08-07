class GameDaySecretaryLinkGameDay < ApplicationRecord
  belongs_to :game_day_secretary_link
  belongs_to :game_day
end
