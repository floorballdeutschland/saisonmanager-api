class Team < ApplicationRecord
  belongs_to :league
  belongs_to :club

  scope :by_club_id, ->(cid) { where(club_id: cid).or(Team.where("#{cid} = ANY (syndicate_clubs)")) }

  def tasks
    Task.where('home_team = ? OR guest_team = ?', id, id)
  end

  def licenses
    Player.find_by_team_id(id)
  end

  def all_club_ids
    ids = [club_id]
    ids += syndicate_clubs if syndicate && syndicate_clubs

    ids
  end

  def all_clubs
    Rails.cache.fetch("#{cache_key}/all_clubs", expires_in: 1.week) do
      all_club_ids.uniq.compact.map { |id| Club.find_by_id(id) }
    end
  end

  def self.teams_by_season(season_id)
    Rails.cache.fetch("Team/teams_by_season/#{season_id}", expires_in: 12.hours) do
      League.where(season_id:).map(&:teams).flatten.uniq
    end
  end

  def logo_url
    return "https://www.saisonmanager.de/team_logos/#{team_logo_path}" if team_logo_path.present?
    # "https://robohash.org/#{name.gsub(/\W/, '').downcase}"
  end

  def logo_small_url
    return "https://www.saisonmanager.de/team_logos/#{team_logo_path}" if team_logo_path.present?
    # "https://robohash.org/#{name.gsub(/\W/, '').downcase}"
  end

  def logo_url_fallback
    return logo_url if logo_url.present?

    club.logo_url
  end

  def logo_small_url_fallback
    return logo_small_url if logo_small_url.present?

    club.logo_small_url
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
      league_name: league.name,
      league_short_name: league.short_name,
      game_operation_id: league.game_operation.id,
      game_operation_name: league.game_operation.name,
      game_operation_short_name: league.game_operation.short_name,
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
end
