class League < ApplicationRecord
  has_many :game_days
  belongs_to :game_operation

  def games(game_day_number = nil)
    gd = game_day_number.present? ? game_days.where(number: game_day_number) : game_days
    gd.includes(:games).map(&:games).flatten.sort_by{ |i| i.game_number.to_i }
  end

  def teams
    Team.where(league_id: id).or(Team.where("'?' = ANY (cup_leagues)", id))
  end

  def similar_leagues
    League.where(season_id: season_id, league_system_id: league_system_id, league_class_id: league_class_id).where.not(id: id)
  end

  def full_hash(include_similar_leagues = false)
    result = {
      id: id,
      game_operation_id: game_operation_id,
      game_operation_name: game_operation.name,
      league_category_id: league_category_id,
      league_class_id: league_class_id,
      league_system_id: league_system_id,
      league_type: league_type,
      name: name,
      female: female,
      enable_scorer: enable_scorer,
      short_name: short_name,
      season_id: season_id,
      order_key: order_key,
      game_day_numbers: game_days.pluck(:number).uniq.sort
    }

    result[:similar_leagues] = similar_leagues.map(&:full_hash) if include_similar_leagues

    result
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

  def league_type
    return 'league' if [1,2,5].include? league_category_id.to_i
    return 'cup' if [3,4].include? league_category_id.to_i
    return 'champ' if league_category_id.to_i >= 100
  end

  def schedule
    games.map(&:schedule_item)
  end

  def game_day_schedule(game_day_number)
    games(game_day_number).map(&:schedule_item)
  end

  def current_schedule
    game_day_number = game_days.pluck(:number).max
    games(game_day_number).map(&:schedule_item)
  end

  def meta_item
    attributes.select {|key, value| ['name', 'short_name', 'order_key'].include?(key) }
  end

  def won_points
    # TODO: old replace with parameter in new system
    league_system_id.to_i == 1 ? 3 : 2
  end

  def draw_points
    # TODO: old replace with parameter in new system
    league_system_id.to_i == 1 ? 1 : 0
  end

  def won_overtime_points
    # TODO: old replace with parameter in new system
    league_system_id.to_i == 1 ? 2 : 0
  end

  def lost_overtime_points
    draw_points
  end

  def scorer
    results = evaluate_scorer
    last_entry = nil
    sorted_results = results.values.sort_by { |player_result| [-(player_result[:goals] + player_result[:assists]), -player_result[:goals], -player_result[:games]] }
    sorted_results.reject! do |player_result|
      (player_result.slice(:goals, :assists, :penalty_2, :penalty_2and2, :penalty_5, :penalty_10, :penalty_ms1, :penalty_ms2, :penalty_ms3).values.sum - player_result[:games] - player_result[:player_id]).zero? # no goals or penalties.
    end

    player_ids = sorted_results.map { |sr| sr[:player_id] }
    players = Player.where(id: player_ids).select(:id, :first_name, :last_name)
    player_lookup = {}
    players.each { |player| player_lookup[player.id] = player }

    next_position_diff = 1
    sorted_results.each_with_index do |player_result, index|
      player = player_lookup[player_result[:player_id]]
      puts player_result[:player_id]
      puts player
      player_result[:first_name] = player.first_name
      player_result[:last_name] = player.last_name
      player_result[:image] = player.image
      player_result[:image_small] = player.image_small
      player_result[:sort] = index
      if last_entry.nil?
        player_result[:position] = 1
      elsif (player_result[:goals] == last_entry[:goals]) &&
            (player_result[:assists] == last_entry[:assists])
        player_result[:position] = last_entry[:position]
        next_position_diff += 1
      else
        player_result[:position] = last_entry[:position] + next_position_diff
        next_position_diff = 1
      end

      last_entry = player_result
    end

    sorted_results.compact
  end

  def table
    results = evaluate_table_results
    last_entry = nil

    sorted_results = results.values.sort_by { |team_result| [-team_result[:points], -team_result[:goals_diff], -team_result[:goals_scored]] }

    next_position_diff = 1
    sorted_results.each_with_index do |team_result, index|
      team_result[:sort] = index
      if last_entry.nil?
        team_result[:position] = 1
      elsif (team_result[:points] == last_entry[:points]) &&
            (team_result[:goals_diff] == last_entry[:goals_diff]) &&
            (team_result[:goals_scored] == last_entry[:goals_scored])
        team_result[:position] = last_entry[:position]
        next_position_diff += 1
      else
        team_result[:position] = last_entry[:position] + next_position_diff
        next_position_diff = 1
      end

      last_entry = team_result
    end

    sorted_results
  end

  def evaluate_scorer
    game_scores = games.map do |game|
      next unless game.ended?

      game.evaluate_scorer
    end.compact

    result = {}

    game_scores.each do |game_score|
      game_score.each do |player_id, score|
        if result.include?(player_id)
          # sum the items
          result[player_id].each do |key, _|
            next if [:player_id, :team_id, :team_name].include?(key)

            result[player_id][key] += score[key]
          end
        else
          # otherwise just set the score
          result[player_id] = score
        end
      end
    end

    result
  end

  def empty_table_item(team)
    league_point_corrections = Setting.point_corrections(id)
    team_point_corrections = league_point_corrections.present? ? league_point_corrections[team.id.to_s] : nil

    {
      games: 0,
      won: 0,
      draw: 0,
      lost: 0,
      won_ot: 0,
      lost_ot: 0,
      goals_scored: 0,
      goals_received: 0,
      goals_diff: 0,
      points: team_point_corrections.present? ? team_point_corrections['points'] : 0,
      team_name: team.name,
      team_id: team.id,
      team_logo: team.logo_url,
      team_logo_small: team.logo_small_url,
      point_corrections: team_point_corrections
    }
  end

  def evaluate_table_results
    results = {}

    games.each do |game|
      next unless game.ended?

      [game.home_team, game.guest_team].each do |team|
        results[team.id] = empty_table_item(team) unless results[team.id].present?

        results[team.id][:games] += 1
      end

      results[game.home_team.id][:goals_scored] += game.result[:home_goals]
      results[game.home_team.id][:goals_received] += game.result[:guest_goals]
      results[game.guest_team.id][:goals_scored] += game.result[:guest_goals]
      results[game.guest_team.id][:goals_received] += game.result[:home_goals]

      # won_points won_overtime_points lost_overtime_points draw_points
      if game.result[:home_goals] == game.result[:guest_goals]
        # draw
        results[game.home_team.id][:draw] += 1
        results[game.guest_team.id][:draw] += 1
        results[game.home_team.id][:points] += draw_points
        results[game.guest_team.id][:points] += draw_points
      elsif game.result[:home_goals] > game.result[:guest_goals]
        # home won
        if game.overtime
          # home won overtime
          results[game.home_team.id][:won_ot] += 1
          results[game.guest_team.id][:lost_ot] += 1
          results[game.home_team.id][:points] += won_overtime_points
          results[game.guest_team.id][:points] += lost_overtime_points
        else
          # home won regular time
          results[game.home_team.id][:won] += 1
          results[game.guest_team.id][:lost] += 1
          results[game.home_team.id][:points] += won_points
        end
      elsif game.result[:home_goals] < game.result[:guest_goals]
        # guest won
        if game.overtime
          # guest won overtime
          results[game.guest_team.id][:won_ot] += 1
          results[game.home_team.id][:lost_ot] += 1
          results[game.guest_team.id][:points] += won_overtime_points
          results[game.home_team.id][:points] += lost_overtime_points
        else
          # guest won regular time
          results[game.guest_team.id][:won] += 1
          results[game.home_team.id][:lost] += 1
          results[game.guest_team.id][:points] += won_points
        end
      end
    end

    results.each_key do |team_id|
      # calculate goal difference
      results[team_id][:goals_diff] = results[team_id][:goals_scored] - results[team_id][:goals_received]
    end

    # point corrections
    results
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

  def license_pdf
    file = "#{id}lizenzliste.pdf"
    #return File.open(file) if !force && File.exist?(file)

    pdf = ApplicationController.render pdf: "report_filename",
                                       save_to_file: file,
                                       save_only: true,
                                       locals: {
                                         league: self
                                       },
                                       disposition: 'inline',
                                       dpi: '300',
                                       lowquality: true,
                                       template: 'leagues/licenses',
                                       header: {
                                         html: {
                                           template: 'leagues/licenses_header',
                                           locals: {
                                             image: ""
                                           }
                                         }
                                       },
                                       footer: {
                                         html: {
                                           template: "leagues/licenses_footer",
                                           locals: {
                                            league: self
                                           }
                                         }
                                       },
                                       # show_as_html: true,
                                       # model: model,
                                       # dpi: 250,
                                       # viewportSize: "1280x1024",
                                       # footerCenter: "",
                                       # footerLeft: "",
                                       # footerFontSize: 8,
                                       # footerLine: false,
                                       enable_local_file_access: true,

                                       page_size: 'A4',
                                       margin: { top: 24,
                                                 bottom: 20,
                                                 left: 15,
                                                 right: 10 }

    File.open(file, 'wb') do |f|
      f << pdf
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
