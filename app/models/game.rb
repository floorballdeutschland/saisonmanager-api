class Game < ApplicationRecord
  belongs_to :home_team, class_name: 'Team'
  belongs_to :guest_team, class_name: 'Team'
  belongs_to :game_day

  scope :by_referee_id, ->(referee_id) { where('? = any (referee_ids)', referee_id) }
  scope :by_referee_name, lambda { |referee_name|
                            where('referee1_string LIKE :refname OR referee2_string LIKE :refname', refname: "%#{referee_name}%")
                          }

  def league
    game_day.league
  end

  def home_team_name
    home_team.name
  end

  def home_team_player_number
    players['home'].map { |p| { p['trikot_number'] => p['player_id'] } }.reduce(&:merge)
  end

  def guest_team_name
    guest_team.name
  end

  def guest_team_player_number
    players['guest'].map { |p| { p['trikot_number'] => p['player_id'] } }.reduce(&:merge)
  end

  def penalty_mapping(event)
    Setting.current.penalties[event['penalty_id'].to_s]['mapping'].to_sym
  end

  def penalty_mapping_string(event)
    Setting.current.penalties[event['penalty_id'].to_s]['name']
  end

  def penalty_reason(event)
    Setting.current.penalty_codes[event['penalty_code_id'].to_s]
  end

  def error_meta_info
    "league: #{league.name}, go: #{league.game_operation.short_name}"
  end

  def forfait?
    forfait > 0
  end

  def referees
    referees = []

    [referee1_string, referee2_string].each do |ref|
      next unless ref.present?

      match = ref.match(/(?<license_number>\d+)\s(?<last_name>.*),\s(?<first_name>.*)/)

      next unless match.present?

      referees << {
        license_id: match[:license_number],
        first_name: match[:first_name],
        last_name: match[:last_name]
      }
    end

    referees
  end

  def players_with_position
    result = {}

    if players.present?
      %w[home guest].each do |team|
        next unless players[team].present?

        result[team] = players[team].map do |player|
          player['position'] = player['goalkeeper'].present? && player['goalkeeper'] == true ? 'Tor' : 'Feld' # ['Sturm', 'Center', 'Verteidigung'].sample
          player
        end
      end
    end

    result
  end

  def result
    return if (legacy && !(events.present? || forfait?)) || (!legacy && !started)

    home_goals_period = [0, 0, 0, 0]
    guest_goals_period = [0, 0, 0, 0]

    last_item = nil

    if !forfait?
      if events.present?

        home_previous_goals = 0
        guest_previous_goals = 0

        events.sort_by { |e| e[:row] }.each do |e|
          home_goals = e['home_goals'].to_i
          guest_goals = e['guest_goals'].to_i

          next unless home_goals.present? && guest_goals.present?

          if last_item.present? && (e['period'] > last_item['period'])
            home_previous_goals = last_item['home_goals'].to_i
            guest_previous_goals = last_item['guest_goals'].to_i
          end

          home_goals_period[e['period'].to_i - 1] = home_goals - home_previous_goals
          guest_goals_period[e['period'].to_i - 1] = guest_goals - guest_previous_goals

          last_item = e
        end
      else
        last_item = {
          'home_goals' => 0,
          'guest_goals' => 0
        }
      end
    else
      last_item = if forfait == 1
                    {
                      'home_goals' => 0,
                      'guest_goals' => league.forfait_goals
                    }
                  elsif forfait == 2
                    {
                      'home_goals' => league.forfait_goals,
                      'guest_goals' => 0
                    }
                  elsif forfait == 3
                    {
                      'home_goals' => league.forfait_goals * -1,
                      'guest_goals' => league.forfait_goals * -1
                    }
                  end
    end

    {
      home_goals: last_item['home_goals'],
      guest_goals: last_item['guest_goals'],
      home_goals_period:,
      guest_goals_period:,
      postfix: result_postfix,
      forfait: forfait?,
      overtime: (overtime == true)
    }
  end

  def result_postfix
    if forfait > 0
      return {
        short: ' (forfait)',
        long: ' kampflos'
      }
    end

    if overtime == true
      if false # penalty schießen
        return {
          short: 'n. PS',
          long: 'nach Penalty-Schießen'
        }
      else
        return {
          short: 'n.V.',
          long: 'nach Verlängerung'
        }
      end
    end

    {
      short: '',
      long: ''
    }
  end

  def result_string
    res = result
    "#{res[:home_goals]}:#{res[:guest_goals]}#{res[:overtime] ? " #{result_postfix[:short]}" : ''}" if res
  end

  def state
    if record_created_at.present?
      if started && !ended
        :running
      elsif started && ended
        :ended
      else
        # :not_started
        :record_created
      end
    else
      :no_record
    end
  end

  def schedule_item
    item = {
      game_id: id,
      game_number: game_number.to_i,
      game_day: game_day.number,
      arena: game_day.arena_id,
      arena_name: game_day.arena.name,
      arena_address: game_day.arena.address,
      arena_short: game_day.arena.schedule_item,
      hosting_club: game_day.hosting_club,
      game_day_id:,
      date: game_day.date,
      time: start_time,
      started:,
      ended:,
      home_team_name:,
      home_team_logo: home_team.logo_url,
      home_team_small_logo: home_team.logo_small_url,
      guest_team_name:,
      guest_team_logo: guest_team.logo_url,
      guest_team_small_logo: guest_team.logo_small_url,
      nominated_referee_string:,
      referees:,
      notice_type:,
      notice_string:,
      state:
    }

    if started?
      item[:result_string] = result_string
      item[:result] = result
    end

    item
  end

  def empty_score(player_id, team)
    {
      games: 1,
      goals: 0,
      assists: 0,
      penalty_2: 0,
      penalty_2and2: 0,
      penalty_5: 0,
      penalty_10: 0,
      penalty_ms_tech: 0,
      penalty_ms_full: 0,
      penalty_ms1: 0,
      penalty_ms2: 0,
      penalty_ms3: 0,
      player_id:,
      team_id: team.id,
      team_name: team.name
    }
  end

  def evaluate_scorer
    result = {}

    return result if forfait?
    return result if home_team_player_number.blank? && guest_team_player_number.blank?

    home_player_ids = home_team_player_number.present? ? [home_team_player_number.values].flatten.compact.sort : []
    home_player_ids.each do |p|
      result[p] = empty_score(p, home_team)
    end

    guest_player_ids = guest_team_player_number.present? ? [guest_team_player_number.values].flatten.compact.sort : []
    guest_player_ids.each do |p|
      result[p] = empty_score(p, guest_team)
    end

    events.each do |event|
      if event['penalty_id'].present?
        # penalty?
        player_id = event['home_number'].present? ? home_team_player_number[event['home_number']] : guest_team_player_number[event['guest_number']]

        # register penalty for player
        result[player_id][penalty_mapping(event)] += 1 if player_id.present? # skip if no player
      elsif event['home_goals'].present? && event['guest_goals'].present?
        # goal?
        if event['home_number'].present? && event['home_number'].to_i < 1000 # owngoal: 1000
          player_id = home_team_player_number[event['home_number']]
          result[player_id][:goals] += 1 if player_id.present?

          if event['home_assist'].present?
            player_id = home_team_player_number[event['home_assist']]
            result[player_id][:assists] += 1 if player_id.present?
          end
        elsif event['guest_number'].present? && event['guest_number'].to_i < 1000 # owngoal: 1000
          player_id = guest_team_player_number[event['guest_number']]
          result[player_id][:goals] += 1 if player_id.present?

          if event['guest_assist'].present?
            player_id = guest_team_player_number[event['guest_assist']]
            result[player_id][:assists] += 1 if player_id.present?
          end
        end
      end
    end

    result
  end
  # code to debug [24454,24446,24443,24435,24430].each {|g| puts [g, Game.find(g).evaluate_scorer[4413].to_json].join ' ' }

  def full_hash
    {
      id:,
      game_number:,
      start_time:,
      actual_start_time:,
      date: game_day.date,
      game_day: league.game_day_title_hash(game_day.number),
      audience:,
      home_team_name: home_team.name,
      guest_team_name: guest_team.name,
      home_team_id:,
      guest_team_id:,
      home_team_logo: home_team.logo_url,
      home_team_small_logo: home_team.logo_small_url,
      guest_team_logo: guest_team.logo_url,
      guest_team_small_logo: guest_team.logo_small_url,
      live_stream_link:,
      events: formatted_events,
      players: players_with_position,
      started:,
      ended:,
      result_string:,
      result:,
      league_id: league.id,
      league_name: league.name,
      league_short_name: league.short_name,
      game_operation_id: league.game_operation.id,
      game_operation_name: league.game_operation.name,
      game_operation_short_name: league.game_operation.short_name,
      period_titles: league.period_titles,
      arena: game_day.arena_id,
      arena_name: game_day.arena&.name,
      arena_address: game_day.arena&.address,
      arena_short: game_day.arena&.schedule_item,
      nominated_referees: nominated_referee_string,
      deletable: deletable?,
      notice_type:,
      notice_string:,
      referees:
    }
  end

  def hidden_elements
    {
      time_keeper_signed:,
      record_keeper_signed:,
      referee1_signed:,
      referee2_signed:,

      home_captain_signed:,
      guest_captain_signed:,

      protest:,
      special_event:,
      playoff:,
      overtime:,

      home_team_coaches:,
      guest_team_coaches:,

      home_timeout_string:,
      guest_timeout_string:,
      time_keeper_string:,
      record_keeper_string:,
      record_comment:
    }
  end

  def meta_hash
    {
      id:,
      game_number:,
      start_time:,
      game_day_id:,
      audience:,
      home_team_name: home_team.name,
      guest_team_name: guest_team.name,
      home_team_id:,
      guest_team_id:,
      home_team_logo: home_team.logo_url,
      home_team_small_logo: home_team.logo_small_url,
      guest_team_logo: guest_team.logo_url,
      guest_team_small_logo: guest_team.logo_small_url,
      live_stream_link:,
      started:,
      ended:,
      forfait:,
      notice_type:,
      notice_string:,
      nominated_referees: nominated_referee_string,
      referees:
    }
  end

  def referee_export_hash
    {
      id:,
      game_number:,
      start_time:,
      date: game_day.date,
      game_day: league.game_day_title_hash(game_day.number),
      audience:,
      home_team_name: home_team.name,
      guest_team_name: guest_team.name,
      home_team_logo: home_team.logo_url,
      home_team_small_logo: home_team.logo_small_url,
      guest_team_logo: guest_team.logo_url,
      guest_team_small_logo: guest_team.logo_small_url,
      live_stream_link:,
      result_string:,
      result:,
      league_id: league.id,
      league_name: league.name,
      league_short_name: league.short_name,
      game_operation_id: league.game_operation.id,
      game_operation_name: league.game_operation.name,
      game_operation_short_name: league.game_operation.short_name,
      arena: game_day.arena_id,
      arena_name: game_day.arena&.name,
      arena_address: game_day.arena&.address,
      arena_short: game_day.arena&.schedule_item,
      nominated_referees: nominated_referee_string,
      referees:
    }
  end

  # {
  #   id: Int,
  #   home: {
  #     shortName: String, // Kürzel, das wir verwenden, wenn kein Logo hinterlegt ist
  #     name: String,
  #     logoUrl: String
  #   },
  #   guest: {
  #     shortName: String,
  #     name: String,
  #     logoUrl: String
  #   },
  #   periods: Int, // Anzahl der Spielzeiten / Spiel
  #   events: [
  #     {
  #       period: Int,
  #       eventType: String // Momentan "HOME_GOAL" oder "GUEST_GOAL"
  #     }
  #   ],
  #   isLive: Boolean
  # }
  def ticker_hash
    isLive = started && !ended
    hasEnded = !isLive && ended
    {
      id:,
      home: home_team.ticker_hash,
      guest: guest_team.ticker_hash,
      periods: 3,
      events: ticker_events,
      resultString: result_string,
      isLive:,
      hasEnded:,
      startingTime: start_time,
      date: game_day.date,
      url: "https://fvd.saisonmanager.de/index.php?seite=game&game=#{id}"
    }
  end

  def ticker_events
    (events || []).map do |e|
      if e['penalty_code_id'] && e['penalty_code_id'].to_i != 23 # penalty_shot should be goal, not penalty.
        {
          period: e['period'],
          time: e['time'],
          eventType: e['home_number'].present? ? 'HOME_PENALTY' : 'GUEST_PENALTY'
        }
      else
        {
          period: e['period'],
          time: e['time'],
          eventType: e['home_number'].present? ? 'HOME_GOAL' : 'GUEST_GOAL'
        }
      end
    end
  end

  def timeout_events
    [
      extract_timeout_information(home_timeout_string, 'home'),
      extract_timeout_information(guest_timeout_string, 'guest')
    ].compact
  end

  def extract_timeout_information(timeout_string, team)
    # some examples
    # 16:22 / III
    # 17:21 / III
    # 17:21 / III
    # 19:01 / 2
    # 5:50   II
    # 12:42/I
    # 1:02 | I
    # 13:53/2
    # III 8:50
    # III / 8:45
    # III - 9:58
    match = /(?<time>\d?\d:\d\d)/.match timeout_string

    return unless match.present? && match['time'].present?

    match_period = %r{(?<period>(I|V)+)|/\s?(?<period_number>\d{1})}.match timeout_string

    return unless match_period.present? && (match_period['period'].present? || match_period['period_number'].present?)

    period = if match_period['period'].present?
               case match_period['period']
               when 'I'
                 1
               when 'II'
                 2
               when 'III'
                 3
               when 'IV'
                 4
               when 'V'
                 5
               end
             elsif match_period['period_number'].present?
               match_period['period_number'].to_i
             end

    {
      event_id: 9000 + (team == 'home' ? 1 : 2),
      event_type: 'timeout',
      event_team: team,
      period:,
      time: match['time'],
      sortkey: "#{period}-#{match['time'].rjust(5, '0')}"
    }
  end

  def formatted_events
    result = (events || []).map do |event|
      e = {
        event_id: event['id'],
        event_type: nil,
        event_team: nil,
        period: event['period'],
        home_goals: event['home_goals'],
        guest_goals: event['guest_goals'],
        time: event['time'],
        sortkey: "#{event['period']}-#{event['time'].rjust(5, '0')}"
      }

      owngoal = false
      nagoal = false

      e[:event_team] = event['event_team']

      if event['home_number'].present?
        e[:event_team] = 'home' if legacy
        e[:number] = event['home_number']
        owngoal = true if event['home_number'] == 1000
        nagoal  = true if event['home_number'] == 2000
        e[:assist] = event['home_assist'] if event['home_assist'].present?

      elsif event['guest_number'].present?
        e[:event_team] = 'guest' if legacy
        e[:number] = event['guest_number']
        owngoal = true if event['guest_number'] == 1000
        nagoal  = true if event['guest_number'] == 2000
        e[:assist] = event['guest_assist'] if event['guest_assist'].present?
      else
        Sentry.capture_message("missing scorer, game: #{id}, event: #{event.to_json}, #{error_meta_info}")
        next
      end

      if event['penalty_id'].present? && event['penalty_code_id'] && event['penalty_code_id'].to_i != 23 # penalty_shot should be goal, not penalty.
        e[:event_type] = :penalty

        e[:penalty_type] = penalty_mapping(event)
        e[:penalty_type_string] = penalty_mapping_string(event)
        reason = penalty_reason(event)
        e[:penalty_reason] = reason['code']
        e[:penalty_reason_string] = reason['description']

      else
        e[:event_type] = :goal
        if event['penalty_code_id'].to_i != 23
          if owngoal
            e[:goal_type] = :owngoal
            e[:goal_type_string] = 'Eigentor'
          elsif nagoal
            e[:goal_type] = :not_assigned
            e[:goal_type_string] = 'nicht angegeben'
          else
            e[:goal_type] = :regular
            e[:goal_type_string] = 'Tor'
          end

        elsif event['time'] == '70:00'
          e[:goal_type] = :penalty_shots
          e[:goal_type_string] = 'Entscheidung im Penalty-Schießen'
        else
          e[:goal_type] = :penalty_shot
          e[:goal_type_string] = 'Strafschuss'
        end
      end

      # penalty code without a penalty
      if !event['penalty_id'].present? && event['penalty_code_id'] && event['penalty_code_id'].to_i != 23
        Sentry.capture_message("missing penalty code, game: #{id}, event: #{event.to_json}, #{error_meta_info}")
      end

      e
    end.compact

    (result + timeout_events).sort_by { |e| e[:sortkey] }
  end

  def error_missing_overtime_checkbox?
    return false if overtime? # cant be missing, is set
    return false unless events.present? # no events recorded, cant be missing

    # we have overtime entries, but the checkbox is not set (see line 1)
    return true if events.map { |event| event['period'] }.max > league.period_count_normal_game

    false
  end

  def error_overtime_wrong_period?
    return false unless events.present? # no events recorded

    # cant be higher then penalty shots
    return true if events.map { |event| event['period'] }.max > league.period_penalty_shots

    # if its equal to ps, we check the clock to end with :00, normal ps time should be: 70:00 (GF), 50 (KF), youth (35)
    period_penalty_shots = league.period_penalty_shots
    events.map do |event|
      event['period'] == period_penalty_shots && event['time'].last(3) != ':00'
    end.reduce(&:|)
  end

  def error_result_zero_after_goals?
    return false unless events.present? # no events recorded

    scores = events.map { |event| [event['home_goals'], event['guest_goals']] }.map(&:sum)

    error = false
    non_zero = false

    scores.each do |s|
      if s > 0
        non_zero = true
      elsif s == 0 && non_zero
        error = true
        break
      end
    end

    error
  end

  def error_result_not_increasing?
    return false unless events.present? # no events recorded

    scores = events.map { |event| [event['home_goals'], event['guest_goals']] }.map(&:sum)

    # if they dont match, we had an error.
    !(scores == scores.clone.sort)
  end

  def error_last_result_zero_after_goals?; end

  def error_checker
    errors = []

    if error_missing_overtime_checkbox?
      errors << { key: 'missing_overtime_checkbox',
                  text: 'Die Checkbox für Verlängerung wurde nicht ausgewählt, aber es wurde ein Tor in der Verlängerung erzielt', level: :serious }
    end
    if error_overtime_wrong_period?
      errors << { key: 'overtime_wrong_period',
                  text: 'nach der regulären Spielzeit wurden Einträge in der falschen Periode erfasst', level: :serious }
    end
    if error_last_result_zero_after_goals?
      errors << { key: 'last_result_zero_after_goals',
                  text: 'Der letzte Eintrag im Spielbericht ist 0:0, obwohl Tore gefallen sind', level: :serious }
    end
    if error_result_not_increasing?
      errors << { key: 'result_not_increasing', text: 'Die Anzahl der Tore steigt nicht an.',
                  level: :serious }
    end
    if error_result_zero_after_goals?
      errors << { key: 'result_zero_after_goals',
                  text: 'Ein Eintrag im Spielbericht ist 0:0, obwohl vorher Tore gefallen sind', level: :minor }
    end

    errors
  end

  def sort_events!
    events.sort_by! { |e| [e['period'], e['time'].rjust(5, '0'), e['id'], e['row']] }
    home_score = 0
    guest_score = 0

    events.map!.with_index do |e, i|
      e['row'] = i + 1

      unless legacy
        if e['event_type'] == 'goal'
          if e['event_team'] == 'home'
            home_score += 1
          else
            guest_score += 1
          end
        end

        e['home_goals'] = home_score
        e['guest_goals'] = guest_score
      end

      e
    end
  end

  def deletable?
    !started?
  end

  def user_permissions(user)
    perm = []

    go = league.game_operation_id
    game_day_club_id = game_day.club_id

    # we calculate the intersection between this and the users permissions
    #  e.g. [0,1] & [0] => [0]
    #  if we have a non empty array, the permission is present.
    global_or_go = [0, go]

    admin = user.permission_hash[:admin].present? && (global_or_go & user.permission_hash[:admin]).present?
    sbk = user.permission_hash[:sbk].present? && (global_or_go & user.permission_hash[:sbk]).present?
    rsk = user.permission_hash[:rsk].present? && (global_or_go & user.permission_hash[:rsk]).present?

    # edit home team players before game
    if admin || sbk || (user.permission_hash[:vm].to_a & home_team.all_club_ids).present? || user.permission_hash[:vm].to_a.include?(home_team_id)
      perm << :pregame_edit_home
    end
    # edit guest team players before game
    if admin || sbk || (user.permission_hash[:vm].to_a & guest_team.all_club_ids).present? || user.permission_hash[:vm].to_a.include?(guest_team_id)
      perm << :pregame_edit_guest
    end

    # only allowed to edit nominated_referees
    perm << :edit_referee_nomination if admin || sbk || rsk

    # edit all game info
    perm << :edit_game_report if admin || sbk || user.permission_hash[:vm].to_a.include?(game_day_club_id)
    # TODO: add TM access on club level

    # edit all game info
    perm << :edit_game if admin || sbk

    perm
  end

  def self.start_end_games
    return
    gds = GameDay.where date: Date.today
    games = gds.map(&:games).map(&:all).flatten
    t = Time.now

    filtered_games = games.select do |g|
      hour, minute = g.start_time.split(':')

      hour.to_i <= t.hour && minute.to_i < t.min
    end

    gds_yesterday = GameDay.where date: Date.yesterday
    games_yesterday = gds_yesterday.map(&:games).map(&:all).flatten

    all_games = [filtered_games, games_yesterday].flatten.compact

    all_games.each do |g|
      if !g.started? && g.players.present? && g.players['home'].present? && g.players['guest'].present?
        g.started = true
        g.save
      end
      if g.started? && !g.ended? && g.time_keeper_signed? && g.record_keeper_signed? && g.referee1_signed? && g.referee2_signed?
        g.ended = true
        g.save
      end
    end
  end
end
