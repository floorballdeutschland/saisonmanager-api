class Club < ApplicationRecord
  has_many :game_days

  has_one_attached :logo

  def teams
    Team.by_club_id(id)
  end

  def current_teams
    teams.current_season
  end

  def players
    p = Player.where("players.clubs @> '[{\"club_id\": ?}]'", id).order(:last_name, :first_name)
    p.select do |pl|
      pl.clubs.map do |c|
        if c['club_id'] != id
          false
        elsif c['valid_until'].present?
          (c['valid_until'].to_date >= Time.now)
        else
          true
        end
      end.reduce(&:|)
    end
  end

  def home_game_operation
    Rails.cache.fetch("#{cache_key}/home_game_operation", expires_in: 1.week) do
      go = game_operations_hash.select { |g| g['home_game_operation'] == true }
      GameOperation.find_by_id go.first['game_operation_id'] if go.present?
    end
  end

  def update_state
    return if postcode.blank?

    states = Club.postcodes.select { |pc| pc[:from] < postcode.to_i && pc[:till] > postcode.to_i }

    if states.present?
      state = states.first[:isocode]
      update_attributes(state:)
    end
  end

  def full_hash
    {
      id:,
      long_name:,
      name:,
      short_name:,
      state:,
      logo_url:,
      logo_small_url:,
      game_operation_id: main_game_operation_id,
      additional_game_operation_ids:
    }
  end

  def main_game_operation_id
    game_operations_hash.filter { |h| h['home_game_operation'] }.map { |h| h['game_operation_id'].to_i }.first
  end

  def additional_game_operation_ids
    game_operations_hash.filter { |h| !h['home_game_operation'] }.map { |h| h['game_operation_id'].to_i }
  end

  def fix_game_operations_hash!
    game_operations_hash.map! do |goh|
      if goh['game_operation_id'].present? && goh['game_operation_id'].instance_of?(String)
        goh['game_operation_id'] = goh['game_operation_id'].to_i
      end

      goh
    end

    save
  end

  def logo_url
    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) if logo.present?
  end
  alias logo_small_url logo_url

  def self.admin_club_permissions(user)
    result = []

    # für jeden verband:
    # name, id, kuerzel, ligen
    go_ids = []

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten
    end

    GameOperation.find(go_ids).each do |go|
      item = go.meta_hash
      item[:leagues] = leagues.where(game_operation_id: go.id).map(&:full_hash)
      result << item
    end

    result
  end

  def user_permissions(user)
    perm = []

    go = main_game_operation_id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = [0, go]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?
    rsk = user.permission_hash[:rsk].present? && (global_or_go & user.permission_hash[:rsk]).present?

    # # edit league
    perm << :update_club if admin || sbk

    # edit player
    perm << :update_player if admin || sbk

    if admin || sbk || user.permission_hash[:vm].present? && user.permission_hash[:vm].include?(id)
      perm << :create_player
    end
    # perm << :delete_league if admin || sbk

    perm
  end

  def self.admin_user_clubs(user)
    result = []

    # für jeden verband:
    # name, id, kuerzel, ligen
    go_ids = []

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten
    end

    GameOperation.find(go_ids).each do |go|
      item = go.meta_hash
      item[:clubs] = go.clubs.map(&:full_hash)
      result << item
    end

    result
  end

  def add_logo(force = false)
    return if !force && logo.present?

    dir = Dir["tmp/logovereine/#{id}*.png"]
    return unless dir.present?

    path = dir.first
    filename = path.split('/').last

    logo.attach(io: File.open(path), filename:, content_type: 'image/png')
  end

  def self.add_logos
    Club.all.each do |club|
      club.add_logo
    end
  end
end
