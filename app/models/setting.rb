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

end
