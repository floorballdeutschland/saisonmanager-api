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
    Team.where(league_id: id).or(Team.where("#{id} = ANY (cup_leagues)")).order(:name)
  end

  # returns:
  # {
  #   id: Int,
  #   leagueName: String,
  #   leagueShortName: String,
  #   matchDays: [
  #     {
  #       games: [ Int ] // Liste von Spiel ids
  #     }
  #   ]
  # }
  def ticker_hash
    {
      id: id,
      leagueName: name,
      leagueShortName: short_name,
      sortKey: order_key,
      gameDays: game_days_for_ticker
    }
  end

  def game_days_for_ticker
    gameday_whitelist = Setting.game_day_for_league id, season_id

    temp = {}
    game_days.where(number: gameday_whitelist).includes(:games).each do |gd|
      temp[gd.number] ||= []
      temp[gd.number] << gd.game_ids
      temp[gd.number].flatten!
    end

    temp.map do |k,v|
      {
        gameDayNumber: k,
        title: ['3', '4'].include?(league_category_id) ? game_day_title_cup(k.to_s) : "#{k}. Spieltag",
        games: v
      }
    end.sort { |a,b| a[:gameDayNumber] <=> b[:gameDayNumber] }
  end

  def game_day_title_cup(game_day_number)
    best_of_eight = Setting.start_best_of_eight id

    if best_of_eight.present?
      case game_day_number
        when best_of_eight.to_s
          'Achtenfinale'
        when (best_of_eight + 1).to_s
          'Viertelfinale'
        when (best_of_eight + 2).to_s
          'Halbfinale'
        when (best_of_eight + 3).to_s
          'Finale'
        else
          "Runde #{game_day_number}"
        end
    else
      case game_day_number
        when "4"
          'Achtenfinale'
        when "5"
          'Viertelfinale'
        when "6"
          'Halbfinale'
        when "7"
          'Finale'
        else
          "Runde #{game_day_number}"
        end
    end

    # if female.present?
    #   case game_day_number
    #   when "1"
    #     'Runde 1'
    #   when "2"
    #     'Achtenfinale'
    #   when "3"
    #     'Viertelfinale'
    #   when "4"
    #     'Halbfinale'
    #   when "5"
    #     'Finale'
    #   end
    # else
    #   case game_day_number
    #   when "4"
    #     'Achtenfinale'
    #   when "5"
    #     'Viertelfinale'
    #   when "6"
    #     'Halbfinale'
    #   when "7"
    #     'Finale'
    #   else
    #     "Runde #{game_day_number}"
    #   end
    # end
  end


  def licenses_csv
    team_ids = teams.map(&:id)

    team_licenses = {}
    teams.each do |team|
      team_licenses[team.id.to_s] = Player.find_by_team_id team.id
    end

    status = {"1"=> "erteilt", "2"=> "beantragt", "3"=> "abgelehnt", "4"=> "gelöscht", "5"=> "Löschung beantragt", "6"=> "Transfer", "7"=> "ignoriert"}

    teams.each do |team|
      puts team.name
      team_licenses[team.id.to_s].each do |player|
        license = player.licenses.select{|l| l["team_id"]==team.id.to_s}.first
      
        last_status = license["history"].last
        last_status_id = last_status["license_status_id"]
        last_status_code = status[last_status_id.to_s]
      
        approved_at = if last_status_id == 1
          last_status["created_at"].to_datetime.strftime("%d.%m.%Y %H:%M:%S")
        end
        requested_at = license["history"].select{|lh| lh["license_status_id"]==2}.last["created_at"].to_datetime.strftime("%d.%m.%Y %H:%M:%S")
      
        puts "#{player.last_name},#{player.first_name},#{last_status_code},#{requested_at},#{approved_at ? approved_at : '-'},#{team.name}"
      end
      
      nil
    end
  end

  def fix_wrong_settings(female, league_category_id, league_class_id)

    team_ids = teams.map(&:id)

    team_licenses = {}
    teams.each do |team|
      team_licenses[team.id.to_s] = Player.find_by_team_id team.id
    end

    teams.each do |team|
      team_licenses[team.id.to_s].each do |player|
        player.licenses.map! do |license|
          if license["team_id"] == team.id.to_s
            license["male"] = !female
            license["league_category_id"] = league_category_id
            license["league_class_id"] = league_class_id
          end
          license
        end
        player.save
      end  
    end

    self.female = female
    self.league_category_id = league_category_id
    self.league_class_id = league_class_id

    self.save
  end
end
