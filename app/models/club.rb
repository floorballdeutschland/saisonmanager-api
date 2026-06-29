class Club < ApplicationRecord
  has_many :game_days
  belongs_to :state_association, optional: true

  has_one_attached :logo

  scope :active, -> { where(deactivated_at: nil) }

  def deactivate!(user_id)
    update!(deactivated_at: Time.current, deactivated_by: user_id)
  end

  def reactivate!
    update!(deactivated_at: nil, deactivated_by: nil)
  end

  def teams
    Team.by_club_id(id)
  end

  def current_teams
    teams.current_season
  end

  def players
    p = Player.active.where("players.clubs @> '[{\"club_id\": ?}]'", id).order(:last_name, :first_name)
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

  def game_operations_hash
    val = super
    val.is_a?(Array) ? val : []
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
      state_association_id:,
      contact_email:,
      logo_url:,
      logo_small_url:,
      game_operation_id: main_game_operation_id,
      additional_game_operation_ids:,
      deactivated_at:,
      deactivated_by:
    }
  end

  # Öffentliche Variante von full_hash – ohne contact_email und interne Felder
  # (deactivated_*), für key-geschützte öffentliche Endpunkte.
  def public_hash
    {
      id:,
      long_name:,
      name:,
      short_name:,
      state:,
      state_association_id:,
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
    Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) if logo.attached?
  end

  def logo_small_url
    return nil unless logo.attached?

    Rails.application.routes.url_helpers.rails_representation_path(
      logo.variant(resize_to_fit: [100, 100]),
      only_path: true
    )
  end

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
      go_ids.flatten!
    end

    GameOperation.includes(state_association: { logo_attachment: :blob }).find(go_ids).each do |go|
      item = go.meta_hash
      item[:leagues] = leagues.where(game_operation_id: go.id).map(&:full_hash)
      result << item
    end

    result
  end

  def user_permissions(user)
    perm = []

    go = main_game_operation_id
    global_or_go = [0, go]
    ph = user.permission_hash

    admin = ph[:admin].present? && (global_or_go & ph[:admin]).any?
    sbk = ph[:sbk].present? && (global_or_go & ph[:sbk]).any?

    perm << :update_club if admin || sbk
    perm << :update_player if admin || sbk

    if admin || sbk || ph[:vm].present? && ph[:vm].include?(id)
      perm << :create_player
    end

    perm
  end

  def self.admin_user_clubs(user, include_deactivated: false)
    result = []
    go_ids = []
    ph = user.permission_hash
    global_access = ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)

    club_scope = include_deactivated ? Club.all : Club.active

    if global_access
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten!
    end

    GameOperation.includes(state_association: { logo_attachment: :blob }).find(go_ids).each do |go|
      item = go.meta_hash
      item[:clubs] = club_scope.where(id: go.clubs.pluck(:id)).order(:name).map(&:full_hash)
      result << item
    end

    unless global_access
      released_sa_ids = StateAssociationRelease
        .current_season
        .where(recipient_game_operation_id: go_ids)
        .pluck(:grantor_state_association_id)

      StateAssociation.where(id: released_sa_ids).order(:name).each do |sa|
        result << {
          id: nil,
          name: "#{sa.name} (freigegeben)",
          short_name: sa.short_name,
          path: nil,
          logo_url: nil,
          logo_quad_url: nil,
          state_association_id: sa.id,
          released: true,
          clubs: club_scope.where(state_association_id: sa.id).order(:name).map(&:full_hash)
        }
      end
    end

    result
  end

  def add_logo(force = false)
    return if !force && logo.attached?

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
