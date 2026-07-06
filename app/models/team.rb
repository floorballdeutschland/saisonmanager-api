class Team < ApplicationRecord
  belongs_to :league
  belongs_to :club

  validates :name, presence: true

  has_one_attached :logo

  scope :by_club_id, ->(cid) { where(club_id: cid).or(Team.where('? = ANY (syndicate_clubs)', cid)) }
  # "Aktuelle Saison" = Teams, deren Liga in der aktuellen Saison (season_id) liegt.
  # Subquery statt joins, damit nachgelagerte .where(id:/club_id:) eindeutig bleiben.
  # (Früher: league_id >= Setting.current_min_league — eine reine ID-Schwelle, die
  # frisch importierte Alt-Saisons mit hohen league_ids fälschlich als aktuell
  # einstufte; season_id ist die korrekte Abgrenzung.)
  scope :current_season, -> { where(league_id: League.current_season.select(:id)) }

  def tasks
    Task.where('home_team = ? OR guest_team = ?', id, id)
  end

  def all_league_ids
    [cup_leagues, league_id].compact.flatten
  end

  def leagues
    League.where(id: all_league_ids)
  end

  def licenses
    Player.find_by_team_id(id)
  end

  def all_club_ids
    ids = [club_id]
    ids += syndicate_clubs if syndicate && syndicate_clubs

    ids.uniq
  end

  def all_clubs
    Club.where(id: all_club_ids)
  end

  def self.teams_by_season(season_id)
    League.where(season_id:).map(&:teams).flatten.uniq
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

  def logo_url_fallback
    return logo_url if logo_url.present?

    club&.logo_url
  end

  def logo_small_url_fallback
    return logo_small_url if logo_small_url.present?

    club&.logo_small_url
  end

  def full_hash(with_contact_person = false)
    h = {
      id:,
      name:,
      short_name:,
      logo: logo_url,
      league_id:,
      cup_leagues:,
      club_id:,
      league_name: league&.name,
      league_short_name: league&.short_name,
      game_operation_id: league&.game_operation&.id,
      game_operation_name: league&.game_operation&.name,
      game_operation_short_name: league&.game_operation&.short_name,
      game_operation_slug: league&.game_operation&.slug,
      syndicate:,
      syndicate_clubs:,
      logo_url: logo_url_fallback,
      logo_small: logo_small_url_fallback
    }

    if with_contact_person
      h[:contact_email] = contact_email
      h[:contact_person] = contact_person
    end

    h
  end

  def licenses(full_license_hash = true, only_current_licenses = true, player_hash_type = :full)
    team_item = full_hash
    team_players = Player.find_by_team_id id

    team_item[:players] = []
    team_players.each do |player|
      player_item = player.some_hash(player_hash_type, full_license_hash, only_current_licenses)

      license = player.licenses.select { |l| l['team_id'].to_i == id }.first
      # license bzw. dessen history kann fehlen/leer sein (z. B. Preround-Kopie
      # ohne "beantragt"-Eintrag oder kein Team-Match) – dann bleiben die
      # Status-Felder nil statt die Team-Lizenzliste abzubrechen.
      history = license&.dig('history') || []

      last_status = history.sort_by { |h| h['created_at'] }.last
      last_status_id = last_status&.dig('license_status_id')
      last_status_code = last_status_id && License::NAMES[last_status_id.to_i]

      approved_at = (last_status['created_at'].to_datetime if last_status_id == 1)
      requested_at = history.select do |lh|
                       lh['license_status_id'] == 2
                     end.last&.dig('created_at')&.to_datetime

      player_item[:team_license] = {
        license:,
        last_status:,
        last_status_id:,
        last_status_code:,
        approved_at:,
        requested_at:
      }

      team_item[:players] << player_item
    end

    team_item
  end

  # {
  #     shortName: String, // Kürzel, das wir verwenden, wenn kein Logo hinterlegt ist
  #     name: String,
  #     logoUrl: String
  #   }
  def ticker_hash
    {
      shortName: short_name.slice(0, 5).split(' ').first.to_s,
      name:,
      logoUrl: logo_url
    }
  end

  def user_permissions(user)
    perm = []

    go = league&.game_operation_id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = go.present? ? [0, go] : [0]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?

    # # edit league
    perm << :update_team if admin || sbk
    # perm << :delete_league if admin || sbk

    perm
  end

  def self.add_teams_to_cup!(team_ids, cup_id)
    teams = Team.find(team_ids)

    teams.each do |team|
      team.cup_leagues ||= []
      team.cup_leagues << cup_id
      team.save
    end
  end

  def add_logo(force = false)
    return if !force && logo.attached?

    dir = Dir["tmp/logoteams/#{id}*.png"]
    return unless dir.present?

    path = dir.first
    filename = path.split('/').last

    logo.attach(io: File.open(path), filename:, content_type: 'image/png')
  end

  def self.add_logos
    teams = Team.all
    teams.each do |team|
      team.add_logo
    end
  end
end
