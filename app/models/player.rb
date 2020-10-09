class Player < ApplicationRecord

  belongs_to :created_at_user, class_name: "User", optional: true
  belongs_to :updated_at_user, class_name: "User", optional: true

  attr_accessor :hash, :prefix

  def nation_string
    setting = Setting.first
    nations = setting["nations"]

    nations[nation_id.to_s]["name"]
  end

  def created_by_string
    created_at_user.user_name if created_at_user.present?
  end

  def updated_by_string
    updated_at_user.user_name if updated_at_user.present?
  end

  def main_license_hash(season_id, deadline = Date.today)
    # player clubs
    club_names = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.name : 'CLUB(FEHLER)'
    end

    club_ids = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.id : nil
    end.compact

    sorted_licenses = current_licenses(season_id).map! { |x| x["sorting"]= (x["league_category_id"].to_s.rjust(3,'0') + x["league_class_id"].to_s.rjust(3,'0')).to_i; x } if current_licenses(season_id)
    license = select_license sorted_licenses if sorted_licenses

    p=create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
    p.merge(other_license_count: (sorted_licenses || []).count - 1) if p
  end

  def secondary_license_hash(season_id, deadline = Date.today)
    # player clubs
    club_names = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.name : 'CLUB(FEHLER)'
    end

    club_ids = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.id : nil
    end.compact

    sorted_licenses = current_licenses(season_id).map! { |x| x["sorting"]= (x["league_category_id"].to_s.rjust(3,'0') + x["league_class_id"].to_s.rjust(3,'0')).to_i; x } if current_licenses(season_id)
    licenses = other_licenses sorted_licenses if sorted_licenses

    licenses.map do |license|
      create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
    end if sorted_licenses
  end


  def create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
    p = HashWithIndifferentAccess.new({
          id: id,
          last_name: last_name,
          first_name: first_name,
          birthdate: birthdate,
          male: male,
          license_hash: sorted_licenses,
          license: license.to_json.to_s,
          clubs: club_names.to_json,
          club_ids: club_ids.to_json
        })

    valid_home_club = home_club(deadline)
    p.merge!(home_club_id: valid_home_club.id,
            home_club: valid_home_club.name,
            home_club_operation: valid_home_club.home_game_operation.name,
            home_club_state: valid_home_club.state) if valid_home_club

    p.merge!(team_id: license['team_id'],
            license_id: license['id'],
            league_class_id: license['league_class_id'],
            league_class: Setting.league_class(license['league_class_id']),
            league_category_id: license['league_category_id'],
            league_category: Setting.league_category(license['league_category_id'])) if license

    team = Team.find_by_id license['team_id'] if license
    team_clubs = team.all_clubs if team
    if team_clubs.present?
      p.merge!(license_clubs: team_clubs.to_json, license_club: '', league_id: team.league_id)

      if team_clubs.map(&:id).include? p[:license_hash_id]
        p[:license_club] = p[:home_club]
        p[:license_club_state] = p[:home_club_state]
      elsif (team_clubs.map(&:id) & club_ids).size > 0
        # check which club should be choosen
        club = Club.find_by_id (team_clubs.map(&:id) & club_ids).first
        p[:license_club] = club ? club.name : 'FEHLER (LC)'
        p[:license_club_state] = club ? club.state : 'FEHLER (LCS)'
      else
        # check which club should be choosen
        club = Club.find_by_id team_clubs.first.id
        p[:license_club] = club ? club.name : 'FEHLER (LCA)'
        p[:license_club_state] = club ? club.state : 'FEHLER (LCSA)'
      end
    end

    p
  end

  def valid_clubs(deadline)
    clubs.reject { |l| valid_time?(l['valid_until'], deadline) } if clubs
  end

  def home_club(deadline)
    Club.find_by_id home_club_hash(deadline).last['club_id']
  end

  def home_club_hash(deadline)
    valid_clubs(deadline).reject { |l| !l['home_club'] || valid_time?(l['valid_until'], deadline) } if clubs
  end

  def current_licenses(sid)
    result = licenses.reject { |l| !Team.teams_by_season(sid).map(&:id).map(&:to_s).include?(l['team_id'].to_s) } if licenses
    result.map { |x| x["sorting"]= (x["league_category_id"].to_s.rjust(3,'0') + x["league_class_id"].to_s.rjust(3,'0')).to_i; x } if result
  end

  def transfer(new_club_id, user_id)
    # get clubs
    player_clubs = clubs
    # find old club
    old_club = nil
    player_clubs.each do |c|
      old_club = c["club_id"] if c["home_club"] == true && c["valid_until"].nil?
    end

    player_clubs.map! do |c|
      # only valid entries
      if c["valid_until"].nil? || c["valid_until"] > Time.now
        if c["home_club"] == true
          # set all home clubs unvalid
          c["valid_until"] = Time.now
          c["valid_set_by"] = user_id
        else
          # set all non home clubs unvalid
          c["valid_until"] = Time.now
          c["valid_set_by"] = user_id
        end
      end

      c
    end

    # set new home club
    player_clubs << {
      "club_id"=>new_club_id,
      "home_club"=>true,
      "created_at"=>Time.now,
      "created_by"=>user_id
    }

    updated_by_user = User.find user_id

    Transfer.create({
      created_by: user_id,
      former_club_id: old_club,
      new_club_id: new_club_id,
      player_id: id,
      season_id: Setting.current_season
    })

    save!(:validate => false)

  end

  def self.find_by_team_id(team_id)
    # alternative for array: extr_licenses->>'team_id' IN ('#{team_ids.join '\', \''
    Player.find_by_sql "select * from (SELECT *, jsonb_array_elements(licenses) as extr_licenses FROM players ) as subqry WHERE extr_licenses->>'team_id' ='#{team_id}' ORDER BY extr_licenses->>'team_id', last_name, first_name"
  end

  

  private
  def valid_time?(time, deadline)
    !time.nil? && Date.parse(time) < deadline
  end

  def select_license(licenses)
    licenses.map! do |license|
      last_status = license['history'].last
      license.merge last_status
    end

    #licenses.min_by{|x| x['sorting'] }
    sorted = licenses.sort_by{|x| x['sorting'] }
    sorted.first
  end

  def other_licenses(licenses)
    selected = select_license(licenses)

    licenses.reject{ |l| l["id"] == selected["id"] }
  end
end
