class GameOperation < ApplicationRecord
  has_many :leagues

  default_scope { order(id: :asc) }

  def games
    leagues.map(&:games).flatten.sort_by{|i| i.game_number.to_i}
  end

  def short_hash
    attributes.with_indifferent_access.slice(:id, :name, :short_name, :path, :logo_url, :logo_quad_url)
  end
end
