class Setting < ApplicationRecord
  def self.league_class(league_class_id)
    current['league_classes']&.dig(league_class_id.to_s, 'name').to_s
  end

  def self.league_category(league_category_id)
    current['league_categories'][league_category_id.to_s]['name'].to_s
  end

  def self.current
    Setting.first
  end

  def self.current_season
    current.seasons[current_season_id.to_s]
  end

  def self.current_season_id
    current.systems['1']['current_season_id']
  end

  def self.current_min_league
    current_season['min_league_id'] || 0
  end

  def self.current_min_team
    current_season['min_team_id'] || 0
  end

  def self.seasons
    current.seasons.map do |k, v|
      { id: k.to_i, name: v['name'], current: (k.to_i == current_season_id) }
    end.reverse
  end

  def self.point_corrections(league_id)
    current.point_corrections[league_id.to_s]
  end

  # {
  #   "game_day_for_league": {
  #     "780": [1,2],
  #     "781": [4,5],
  #     "782": [6,7],
  #     "783": [1,2]
  #   }
  # }.with_indifferent_access

  def self.liveticker_leagues(season_id = current_season_id, _goid = 1)
    current.liveticker['game_day_for_league']&.[](season_id.to_s)&.keys
  end

  def self.game_day_for_league(league_id, season_id = current_season_id)
    current.liveticker['game_day_for_league']&.[](season_id.to_s)&.[](league_id.to_s)
  end

  def self.start_best_of_eight(league_id)
    current.liveticker['cup_best_of_eight']&.[](league_id.to_s)
  end
end
