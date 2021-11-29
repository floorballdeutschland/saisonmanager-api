class Team < ApplicationRecord
  def tasks
    Task.where("home_team = ? OR guest_team = ?", self.id, self.id)
  end

  def all_clubs
    Rails.cache.fetch("#{cache_key}/all_clubs", expires_in: 1.week) do
      ids = [club_id]
      ids += syndicate_clubs if syndicate && syndicate_clubs

      ids.uniq.compact.map { |id| Club.find_by_id(id) }
    end
  end

  def self.teams_by_season(season_id)
    Rails.cache.fetch("Team/teams_by_season/#{season_id}", expires_in: 12.hours) do
      League.where(season_id: season_id).map(&:teams).flatten.uniq
    end
  end

  def logo_url
    return "https://www.saisonmanager.de/team_logos/#{team_logo_path}" if team_logo_path.present?
    #"https://robohash.org/#{name.gsub(/\W/, '').downcase}"
  end

  def logo_small_url
    return "https://www.saisonmanager.de/team_logos/#{team_logo_path}" if team_logo_path.present?
    #"https://robohash.org/#{name.gsub(/\W/, '').downcase}"
  end

  # {
  #     shortName: String, // Kürzel, das wir verwenden, wenn kein Logo hinterlegt ist
  #     name: String,
  #     logoUrl: String
  #   }
  def ticker_hash
    {
      shortName: short_name.slice(0,5).split(' ').first.to_s,
      name: name,
      logoUrl: logo_url
    }
  end
end
