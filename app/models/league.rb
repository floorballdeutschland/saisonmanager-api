class League < ApplicationRecord
  include UserTrackable

  has_many :game_days
  belongs_to :game_operation

  validates :name, presence: true
  validates :season_id, presence: true

  default_scope { order(:season_id, :game_operation_id).order('order_key::int') }
  scope :current_season, -> { where(season_id: Setting.current_season_id) }

  before_create :set_defaults

  def games(game_day_number = nil)
    gd = game_day_number.present? ? game_days.where(number: game_day_number) : game_days
    gd.includes(:arena, games: [home_team: :club, guest_team: :club]).map(&:games).flatten.sort_by { |i| i.game_number.to_i }
  end

  def teams
    Team.where(league_id: id).or(Team.where("'?' = ANY (cup_leagues)", id))
  end

  def similar_leagues
    League.where(season_id:, league_system_id:,
                 league_class_id:).where.not(id:)
  end

  def forfait_goals
    return 5 if legacy_league && [1, 4, 102].include?(league_category_id.to_i) # GF, Pokal GF, GF DM
    return 8 if legacy_league

    return 5 if field_size == 'GF'

    8
  end

  def period_count_normal_game
    case league_category_id.to_i
    when 1, 4, 102 # GF, Pokal GF, GF DM
      3
    else
      2
    end
  end

  def period_overtime
    period_count_normal_game + 1
  end

  def period_penalty_shots
    period_overtime + 1
  end

  def period_titles
    thirds = if legacy_league
               period_count_normal_game == 3
             else
               periods == 3
             end

    if thirds
      [
        { period: 1, short_title: '1', title: '1. Drittel', status_id: 'period1', can_end_game: false, optional: false,
          running: true },
        { period: 1.5, short_title: 'P1', title: '1. Drittelpause', status_id: 'pause1', can_end_game: false,
          optional: false, running: false },
        { period: 2, short_title: '2', title: '2. Drittel', status_id: 'period2', can_end_game: false, optional: false,
          running: true },
        { period: 2.5, short_title: 'P2', title: '2. Drittelpause', status_id: 'pause2', can_end_game: false,
          optional: false, running: false },
        { period: 3, short_title: '3', title: '3. Drittel', status_id: 'period3', can_end_game: true, optional: false,
          running: true },
        { period: 3.5, short_title: 'PV', title: 'Pause vor Verlängerung', status_id: 'pause_et', can_end_game: false,
          optional: true, running: false },
        { period: 4, short_title: 'V', title: 'Verlängerung', status_id: 'extratime', can_end_game: true,
          optional: true, running: true },
        { period: 4.5, short_title: 'PP', title: 'Pause vor Penalty-Schießen', status_id: 'pause_ps',
          can_end_game: false, optional: true, running: false },
        { period: 5, short_title: 'P', title: 'Penalty-Schießen', status_id: 'penalty_shots', can_end_game: true,
          optional: true, running: true }
      ]
    else
      [
        { period: 1, short_title: '1', title: '1. Hälfte', status_id: 'period1', can_end_game: false, optional: false,
          running: true },
        { period: 1.5, short_title: 'HZ', title: 'Halbzeitpause', status_id: 'pause1', can_end_game: false,
          optional: false, running: false },
        { period: 2, short_title: '2', title: '2. Hälfte', status_id: 'period2', can_end_game: true, optional: false,
          running: true },
        { period: 2.5, short_title: 'PV', title: 'Pause vor Verlängerung', status_id: 'pause_et', can_end_game: false,
          optional: true, running: false },
        { period: 3, short_title: 'V', title: 'Verlängerung', status_id: 'extratime', can_end_game: true,
          optional: true, running: true },
        { period: 4.5, short_title: 'PP', title: 'Pause vor Penalty-Schießen', status_id: 'pause_ps',
          can_end_game: false, optional: true, running: false },
        { period: 4, short_title: 'P', title: 'Penalty-Schießen', status_id: 'penalty_shots', can_end_game: true,
          optional: true, running: true }
      ]
    end
  end

  def period_title(period)
    period_titles.select { |pt| pt[:period] == period }.first
  end

  def period_title_by_id(status_id)
    period_titles.select { |pt| pt[:status_id] == status_id }.first
  end

  def period_time(period)
    return period_length if period <= periods

    return overtime_length if period == periods + 1

    0
  end

  def period_is_extratime(period)
    period == periods + 1
  end

  def full_hash(include_similar_leagues = false)
    result = {
      id:,
      game_operation_id:,
      game_operation_name: game_operation.name,
      game_operation_short_name: game_operation.short_name,
      game_operation_slug: game_operation.slug,
      league_category_id:,
      league_class_id:,
      league_system_id:,
      league_type:, # legacy!
      name:,
      female:,
      enable_scorer:,
      short_name:,
      season_id:,
      order_key:,
      game_day_numbers:,
      game_day_titles:,

      deadline:,
      before_deadline:,

      legacy_league:,
      field_size:,
      league_modus:,
      has_preround:,

      # league_id_preseason: league_id_preseason,
      # league_id_preround: league_id_preround,
      # preround_point_modus: preround_point_modus,
      # preround_scorer_modus: preround_scorer_modus,
      table_modus:,
      direct_comparison:,
      periods:,
      period_length:,
      overtime_length:,
      required_documents: required_documents || []
    }

    result[:similar_leagues] = similar_leagues.map(&:full_hash) if include_similar_leagues

    result
  end

  def hash_with_teams
    hash = full_hash

    hash[:teams] = teams.map(&:full_hash)

    hash
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
    if legacy_league
      return 'league' if [1, 2, 5].include? league_category_id.to_i
      return 'cup' if [3, 4].include? league_category_id.to_i
      return 'champ' if league_category_id.to_i >= 100
    else
      league_modus
    end
  end

  def game_day_numbers
    game_days.pluck(:number).uniq.sort
  end

  def schedule
    games.map(&:schedule_item).sort_by do |game|
      [game[:game_day].to_i, game[:date], game[:time], game[:game_number]]
    end
  end

  def game_day_schedule(game_day_number)
    games(game_day_number).map(&:schedule_item).sort_by do |game|
      [game[:game_day].to_i, game[:date], game[:time], game[:game_number]]
    end
  end

  def current_schedule
    today = Time.zone.today
    game_day_distance = {}
    game_day_numbers.each do |gdn|
      dates = game_days.where(number: gdn).pluck(:date).map { |d| d.try(:to_date) }.compact
      date_diffs = dates.map { |d| (d - today).to_i.abs }
      game_day_distance[date_diffs.sum(0.0) / date_diffs.size] = gdn
    end

    game_day_number = begin
      game_day_distance[game_day_distance.keys.min]
    rescue StandardError
      game_days.pluck(:number).max
    end
    games(game_day_number).map(&:schedule_item)
  end

  def meta_item
    attributes.select { |key, _value| %w[name short_name order_key].include?(key) }
  end

  def won_points
    if legacy_league
      league_system_id.to_i == 1 ? 3 : 2
    else
      case table_modus
      when 'classic'
        3
      else
        10
      end
    end
  end

  def draw_points
    if legacy_league
      league_system_id.to_i == 1 ? 1 : 0
    else
      case table_modus
      when 'classic'
        1
      else
        1
      end
    end
  end

  def won_overtime_points
    if legacy_league
      league_system_id.to_i == 1 ? 2 : 0
    else
      case table_modus
      when 'classic'
        2
      else
        0
      end
    end
  end

  def lost_overtime_points
    draw_points
  end

  def scorer
    results = evaluate_scorer
    last_entry = nil
    sorted_results = results.values.sort_by do |player_result|
      [-(player_result[:goals] + player_result[:assists]), -player_result[:goals], -player_result[:games]]
    end
    sorted_results.reject! do |player_result|
      (player_result.slice(:goals, :assists, :penalty_2, :penalty_2and2, :penalty_5, :penalty_10, :penalty_ms_tech, :penalty_ms_full, :penalty_ms1, :penalty_ms2, :penalty_ms3).values.sum - player_result[:games] - player_result[:player_id]).zero? # no goals or penalties.
    end

    player_ids = sorted_results.map { |sr| sr[:player_id] }
    players = Player.where(id: player_ids).select(:id, :first_name, :last_name)
    player_lookup = {}
    players.each { |player| player_lookup[player.id] = player }

    sorted_results.reject! { |sr| player_lookup[sr[:player_id]].nil? }

    next_position_diff = 1
    sorted_results.each_with_index do |player_result, index|
      player = player_lookup[player_result[:player_id]]
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
    g = games
    results = evaluate_table_results(g)

    sorted_results = if direct_comparison
                       sort_by_direct_comparison(results.values, g)
                     else
                       results.values.sort_by do |r|
                         [-r[:points], -r[:goals_diff], -r[:goals_scored]]
                       end
                     end

    last_entry = nil
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

  def grouped_table
    all_games = games
    groups = all_games.map(&:group_identifier).uniq.reject(&:nil?).sort
    grouped = {}

    groups.each do |group|
      grouped[group] = group_template(group)

      group_games = all_games.select { |game| game.group_identifier == group }
      results = evaluate_table_results(group_games)

      sorted_results = if direct_comparison
                         sort_by_direct_comparison(results.values, group_games)
                       else
                         results.values.sort_by do |r|
                           [-r[:points], -r[:goals_diff], -r[:goals_scored]]
                         end
                       end

      last_entry = nil
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

      grouped[group][:table] = sorted_results
    end

    grouped
  end

  def evaluate_scorer
    game_scores = games.map do |game|
      next unless game.ended? && !game.result.nil?

      game.evaluate_scorer
    end.compact

    result = {}

    game_scores.each do |game_score|
      game_score.each do |player_id, score|
        if result.include?(player_id)
          # sum the items
          result[player_id].each do |key, _|
            next if %i[player_id team_id team_name].include?(key)

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
      team_logo: team.logo_url_fallback,
      team_logo_small: team.logo_small_url_fallback,
      point_corrections: team_point_corrections
    }
  end

  def evaluate_table_results(g = games)
    results = {}

    # Pre-populate all league teams so teams with no games still appear
    teams.each { |team| results[team.id] = empty_table_item(team) }

    g.each do |game|
      [game.home_team, game.guest_team].each do |team|
        results[team.id] ||= empty_table_item(team)
      end

      next unless game.ended? && !game.result.nil?

      [game.home_team, game.guest_team].each do |team|
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
        results[game.home_team.id][:points] += draw_points if game.forfait != 3
        results[game.guest_team.id][:points] += draw_points if game.forfait != 3
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
      id:,
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

    temp.map do |k, v|
      {
        gameDayNumber: k,
        title: game_day_title(k.to_s),
        games: v
      }
    end.sort { |a, b| a[:gameDayNumber] <=> b[:gameDayNumber] }
  end

  def game_day_titles
    titles = []
    game_day_numbers.each do |game_day_number|
      titles << game_day_title_hash(game_day_number)
    end

    titles
  end

  def game_day_title_hash(game_day_number)
    { game_day_number:, title: game_day_title(game_day_number) }
  end

  def game_day_title(game_day_number)
    return game_day_title_cup(game_day_number.to_s) if %w[3 4].include?(league_category_id)

    "#{game_day_number}. Spieltag"
  end

  def game_day_title_cup(game_day_number)
    best_of_eight = Setting.start_best_of_eight id

    if best_of_eight.present?
      case game_day_number
      when best_of_eight.to_s
        'Achtelfinale'
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
      when '4'
        'Achtenfinale'
      when '5'
        'Viertelfinale'
      when '6'
        'Halbfinale'
      when '7'
        'Finale'
      else
        "Runde #{game_day_number}"
      end
    end
  end

  def licenses(full_license_hash = true, only_current_licenses = true)
    team_licenses = {}
    teams.each do |team|
      team_licenses[team.id.to_s] = Player.find_by_team_id team.id
    end

    our_team_ids = teams.map(&:id).to_set

    # Collect all foreign team IDs referenced in player licenses for batch loading
    foreign_team_ids = Set.new
    team_licenses.each_value do |players|
      players.each do |player|
        player.licenses.each do |l|
          t_id = l['team_id'].to_i
          foreign_team_ids << t_id unless our_team_ids.include?(t_id)
        end
      end
    end
    foreign_teams = Team.includes(:leagues).where(id: foreign_team_ids.to_a).index_by(&:id)

    active_statuses = [License::APPROVED, License::REQUESTED].to_set

    result = []
    teams.each do |team|
      team_item = team.full_hash

      team_item[:players] = []
      team_licenses[team.id.to_s].each do |player|
        player_item = player.full_hash(full_license_hash, only_current_licenses)

        license = player.licenses.find { |l| l['team_id'].to_i == team.id }

        last_status = license['history'].max_by { |h| h['created_at'] }
        last_status_id = last_status['license_status_id']
        last_status_code = License::NAMES[last_status_id.to_i]

        approved_at = (last_status['created_at'].to_datetime if last_status_id == 1)
        requested_at = license['history'].select do |lh|
                         lh['license_status_id'] == 2
                       end.last&.dig('created_at')&.then { |ts| ts.to_datetime }

        player_item[:team_license] = {
          license:,
          last_status:,
          last_status_id:,
          last_status_code:,
          approved_at:,
          requested_at:
        }

        player_item[:other_licenses] = player.licenses.filter_map do |l|
          t_id = l['team_id'].to_i
          next if t_id == team.id

          current_status = l['history'].max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
          next unless active_statuses.include?(current_status)

          other_team = foreign_teams[t_id]
          next unless other_team

          { team_name: other_team.name, league_name: other_team.leagues.first&.short_name }
        end

        team_item[:players] << player_item
      end

      result << team_item
    end

    result
  end

  def licenses_csv
    team_ids = teams.map(&:id)

    team_licenses = {}
    teams.each do |team|
      team_licenses[team.id.to_s] = Player.find_by_team_id team.id
    end

    status = { '1' => 'erteilt', '2' => 'beantragt', '3' => 'abgelehnt', '4' => 'gelöscht', '5' => 'Löschung beantragt',
               '6' => 'Transfer', '7' => 'ignoriert' }

    teams.each do |team|
      puts team.name
      team_licenses[team.id.to_s].each do |player|
        license = player.licenses.select { |l| l['team_id'] == team.id.to_s }.first

        last_status = license['history'].last
        last_status_id = last_status['license_status_id']
        last_status_code = status[last_status_id.to_s]

        approved_at = (last_status['created_at'].to_datetime.strftime('%d.%m.%Y %H:%M:%S') if last_status_id == 1)
        requested_at = license['history'].select do |lh|
                         lh['license_status_id'] == 2
                       end.last&.dig('created_at')&.then { |ts| ts.to_datetime }.strftime('%d.%m.%Y %H:%M:%S')

        puts "#{player.last_name},#{player.first_name},#{last_status_code},#{requested_at},#{approved_at || '-'},#{team.name}"
      end

      nil
    end
  end

  def license_pdf
    file = "#{id}lizenzliste.pdf"
    # return File.open(file) if !force && File.exist?(file)

    pdf = ApplicationController.render pdf: 'report_filename',
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
                                             image: ''
                                           }
                                         }
                                       },
                                       footer: {
                                         html: {
                                           template: 'leagues/licenses_footer',
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
          if license['team_id'] == team.id.to_s
            license['league_category_id'] = league_category_id
            license['league_class_id'] = league_class_id
          end
          license
        end
        player.save
      end
    end

    self.female = female
    self.league_category_id = league_category_id
    self.league_class_id = league_class_id

    save
  end

  def delete_games_and_game_days!
    # check for played games
    if games.map(&:deletable?).reduce(&:&)
      ActiveRecord::Base.transaction do
        game_days.each { |gd| gd.games.destroy_all }
        game_days.destroy_all
      end
    end
  end

  def delete_all_licenses!
    teams = Team.where(league_id: id)
    teams.each do |team|
      players = Player.find_by_team_id team.id
      players.each { |p| p.delete_license!(team.id) }
    end
  end

  def remove_games_game_days_licensens_teams!
    ActiveRecord::Base.transaction do
      delete_all_licenses!
      delete_games_and_game_days!
      teams = Team.where(league_id: id)
      teams.destroy_all
    end
  end

  def user_permissions(user)
    perm = []

    go = game_operation_id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = [0, go]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?
    rsk = user.permission_hash[:rsk].present? && (global_or_go & user.permission_hash[:rsk]).present?

    # # edit home team players before game
    # perm << :pregame_edit_home if admin || sbk || (user.permission_hash[:vm].to_a & home_team.all_club_ids).present? || user.permission_hash[:vm].to_a.include?(home_team_id)
    # # edit guest team players before game
    # perm << :pregame_edit_guest if admin || sbk || (user.permission_hash[:vm].to_a & guest_team.all_club_ids).present? || user.permission_hash[:vm].to_a.include?(guest_team_id)

    # # only allowed to edit nominated_referees
    # perm << :edit_referee_nomination if admin || sbk || rsk

    # # edit all game info
    # perm << :edit_game_report if admin || sbk || user.permission_hash[:vm].to_a.include?(game_day_club_id)

    # # edit league
    perm << :update_league if admin || sbk
    perm << :download_template if admin || sbk
    perm << :import_games if admin || sbk
    # perm << :delete_league if admin || sbk

    perm
  end

  def self.admin_user_leagues(user)
    result = []
    leagues = League.current_season.order(season_id: :desc, game_operation_id: :asc).order('order_key::int')

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

    GameOperation.find(go_ids).each do |go|
      item = go.meta_hash
      item[:leagues] = leagues.where(game_operation_id: go.id).map(&:full_hash)
      result << item
    end

    result
  end

  def self.admin_league_permissions(user)
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

    GameOperation.find(go_ids).each do |go|
      item = go.meta_hash
      item[:leagues] = leagues.where(game_operation_id: go.id).map(&:full_hash)
      result << item
    end

    result
  end

  def self.user_leagues_license_list(user)
    result = []
    leagues = nil

    # für jeden verband:
    # name, id, kuerzel, ligen
    go_ids = []

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash

    if ph[:admin].present? || ph[:sbk].present?
      leagues = League.current_season.order(season_id: :desc, game_operation_id: :asc).order('order_key::int')
      if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
        go_ids = GameOperation.all.pluck(:id)
      else
        go_ids << ph[:admin] if ph[:admin].present?
        go_ids << ph[:sbk] if ph[:sbk].present?
        go_ids.flatten!
      end

      GameOperation.find(go_ids).each do |go|
        item = go.meta_hash
        item[:leagues] = leagues.where(game_operation_id: go.id).map(&:full_hash)
        result << item
      end
    elsif ph[:vm].present? || ph[:tm].present? # VM / TM
      # find teams
      teams = if ph[:vm].present?
                clubs = Club.where(id: ph[:vm])
                clubs.map(&:current_teams).flatten.uniq
              elsif ph[:tm].present?
                Team.current_season.where(id: ph[:tm])
              end

      # get all leagues
      leagues = teams.map(&:leagues).flatten.uniq

      go_ids = GameOperation.all.pluck(:id)

      GameOperation.find(go_ids).each do |go|
        item = go.meta_hash
        item[:leagues] = leagues.select do |l|
                           l.game_operation_id == go.id
                         end.sort_by { |l| l.order_key.to_i }.map(&:full_hash)
        result << item if item[:leagues].present?
      end
    end

    result
  end

  private

  def set_defaults
    season_id = Setting.current_season_id if season_id.blank?
  end

  def group_template(group_identifier)
    return {} if group_identifier.nil?

    group = group_identifier.split('_').last

    {
      group_identifier:,
      name: ['Gruppe ', group.upcase].join
    }
  end

  def sort_by_direct_comparison(results_array, all_games)
    by_points = results_array.group_by { |r| r[:points] }
    sorted = []

    by_points.keys.sort.reverse.each do |pts|
      group = by_points[pts]
      if group.size == 1
        sorted << group.first
        next
      end

      group_ids = group.map { |r| r[:team_id] }.to_set
      h2h_games = all_games.select do |g|
        g.ended? && !g.result.nil? &&
          group_ids.include?(g.home_team_id) &&
          group_ids.include?(g.guest_team_id)
      end

      h2h = group.each_with_object({}) do |r, h|
        h[r[:team_id]] = { points: 0, goals_scored: 0, goals_received: 0 }
      end

      h2h_games.each do |game|
        home_id = game.home_team_id
        guest_id = game.guest_team_id
        h2h[home_id][:goals_scored] += game.result[:home_goals]
        h2h[home_id][:goals_received] += game.result[:guest_goals]
        h2h[guest_id][:goals_scored] += game.result[:guest_goals]
        h2h[guest_id][:goals_received] += game.result[:home_goals]

        if game.result[:home_goals] == game.result[:guest_goals]
          h2h[home_id][:points] += draw_points
          h2h[guest_id][:points] += draw_points
        elsif game.result[:home_goals] > game.result[:guest_goals]
          if game.overtime
            h2h[home_id][:points] += won_overtime_points
            h2h[guest_id][:points] += lost_overtime_points
          else
            h2h[home_id][:points] += won_points
          end
        else
          if game.overtime
            h2h[guest_id][:points] += won_overtime_points
            h2h[home_id][:points] += lost_overtime_points
          else
            h2h[guest_id][:points] += won_points
          end
        end
      end

      sorted.concat(group.sort_by do |r|
        tid = r[:team_id]
        h = h2h[tid]
        h2h_diff = h[:goals_scored] - h[:goals_received]
        [-h[:points], -h2h_diff, -h[:goals_scored], -r[:goals_diff], -r[:goals_scored]]
      end)
    end

    sorted
  end
end
