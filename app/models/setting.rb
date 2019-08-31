class Setting < ApplicationRecord

  def self.league_class(league_class_id)
    "#{current['league_classes'][league_class_id.to_s]['name']}"
  end

  def self.league_category(league_category_id)
    "#{current['league_categories'][league_category_id.to_s]['name']}"
  end

  def self.current
    Setting.first
  end

  def self.current_season
    self.current.systems['1']['current_season_id']
  end


  # {
  #   "game_day_for_league": {
  #     "780": [1,2],
  #     "781": [4,5],
  #     "782": [6,7],
  #     "783": [1,2]
  #   }
  # }.with_indifferent_access

  def self.liveticker_leagues
    self.current.liveticker['game_day_for_league'].try(:keys)
  end

  def self.game_day_for_league(league_id)
    self.current.liveticker['game_day_for_league'][league_id.to_s]
  end

  def self.start_best_of_eight(league_id)
    self.current.liveticker['cup_best_of_eight'][league_id.to_s]
  end

end
