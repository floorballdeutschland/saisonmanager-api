class Player < ApplicationRecord

  belongs_to :created_at_user, class_name: "User"
  belongs_to :updated_at_user, class_name: "User"

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

  def license_hash
    # player clubs
    club_names = valid_clubs.map do |club_item| 
      club = Club.find_by_id(club_item['club_id']) 
      club ? club.name : 'CLUB(FEHLER)'
    end

    sorted_licenses = current_licenses.map! { |x| x["sorting"]= (x["league_category_id"].to_s.rjust(3,'0') + x["league_class_id"].to_s.rjust(3,'0')).to_i; x } if current_licenses
    license = select_license sorted_licenses if sorted_licenses

    p = { name: last_name,
          first_name: first_name,
          birthdate: birthdate,
          male: male,
          license_hash: sorted_licenses,
          license: license.to_json.to_s,
          clubs: club_names.to_json }

    p.merge!(home_club_id: home_club.id,
             home_club: home_club.name,
             home_club_operation: home_club.home_game_operation.name) if home_club

  end

  def valid_clubs
    clubs.reject { |l| valid?(l['valid_until']) } if clubs
  end

  def home_club
    Club.find_by_id home_club_hash.last['club_id']
  end

  def home_club_hash
    valid_clubs.reject { |l| !l['home_club'] || valid?(l['valid_until']) } if clubs
  end

  def current_licenses(sid = season_id)
    result = licenses.reject { |l| !Team.teams_by_season(sid).map(&:id).include?(l['team_id']) } if licenses
    result.map { |x| x["sorting"]= (x["league_category_id"].to_s.rjust(3,'0') + x["league_class_id"].to_s.rjust(3,'0')).to_i; x } if result
  end

  private
  def valid?(time)
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

  def deadline
    Date.today
  end

  def season_id
    8
  end
end
