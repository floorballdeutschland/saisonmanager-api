class GameOperation < ApplicationRecord
  has_many :leagues

  default_scope { order(id: :asc) }

  def clubs
    Club.where("clubs.game_operations_hash @> '[{\"game_operation_id\": ?}]'", id).order(:name)
  end

  def games
    leagues.map(&:games).flatten.sort_by { |i| i.game_number.to_i }
  end

  def top_leagues
    leagues.current_season.first(5)
  end

  def slug
    path.presence || short_name&.parameterize
  end

  def meta_hash
    hash = attributes.with_indifferent_access.slice(:id, :name, :short_name, :path, :logo_url, :logo_quad_url, :scan_required)
    hash[:path] = slug
    hash
  end

  def short_hash
    result = meta_hash
    result[:top_leagues] = top_leagues.map(&:full_hash)
    result
  end

  def user_permissions(user)
    perm = []

    go = id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = [0, go]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?
    rsk = user.permission_hash[:rsk].present? && (global_or_go & user.permission_hash[:rsk]).present?

    perm << :create_league if admin || sbk
    perm << :create_team if admin || sbk
    perm << :index_clubs if admin || sbk
    perm << :create_club if admin || sbk

    perm
  end
end
