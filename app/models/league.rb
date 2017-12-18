class League < ApplicationRecord
  has_many :game_days

  def games
    game_days.map(&:games).flatten.sort_by{|i| i.game_number.to_i}
  end

  def league_category
    'league_category'
  end
  
  def league_class
    'league_class'
  end

  def league_system
    'league_system'
  end

  def schedule
    games.map(&:schedule_item)
  end

  def meta_item
    attributes.select {|key, value| ['name', 'short_name', 'order_key'].include?(key) }
  end

  def scorer
    [
      {
        name: 'Jan Hoffmann',
        id: 815,
        place: 1,
        order_key: 1,
        games: 5,
        goals: 10,
        assists: 20,
        penalty_2: 0,
        penalty_5: 0,
        penalty_10: 0,
        penalty_ms: 0
      }
    ]
  end

  def table
    [
      {
        name: "TSV Neuwittenbek",
        id: 123,
        place: 1,
        order_key: 1,
        games: 1,
        points: 3,
        goals_scored: 2,
        goals_received: 0,
        games_won: 1,
        games_draw: 0,
        games_lost: 0,
        games_otwin: 0,
        games_otlost: 0
      }
    ]
  end

  def evaluate_scorer
    player = {}
  end

  def evaluate_table
  end

  def teams
    Rails.cache.fetch("#{cache_key}/teams", expires_in: 12.hours) do
      Team.where("league_id = ? OR ? IN (select(unnest(cup_leagues)))", id, id)
    end
  end
end