class Game < ApplicationRecord
  belongs_to :home_team, class_name: "Team"
  belongs_to :guest_team, class_name: "Team"
  belongs_to :game_day

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

  def forfait?
    forfait > 0
  end

  def referees
    referees = []

    [referee1_string, referee2_string].each do |ref|
      next unless ref.present?

      match = ref.match(/(?<license_number>\d+)\s(?<last_name>.*)\,\s(?<first_name>.*)/)

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

    ['home', 'guest'].each do |team|
      result[team] = players[team].map do |player|
        player['position'] = player['goalkeeper'].present? && player['goalkeeper'] == true ? 'Tor' : 'Feld' # ['Sturm', 'Center', 'Verteidigung'].sample
        player
      end
    end if players.present?

    result
  end

  def result
    return unless events.present? || forfait?

    home_goals_period = [0, 0, 0, 0]
    guest_goals_period = [0, 0, 0, 0]

    last_item = nil

    if !forfait?
      home_previous_goals = 0
      guest_previous_goals = 0

      events.sort_by { |e| e[:row] }.each do |e|
        home_goals = e['home_goals'].to_i
        guest_goals = e['guest_goals'].to_i

        if home_goals.present? && guest_goals.present?
          if last_item.present? && (e['period'] > last_item['period'])
            home_previous_goals = last_item['home_goals'].to_i
            guest_previous_goals = last_item['guest_goals'].to_i
          end

          home_goals_period[e['period'].to_i - 1] = home_goals - home_previous_goals
          guest_goals_period[e['period'].to_i - 1] = guest_goals - guest_previous_goals

          last_item = e
        end
      end
    else
      if forfait == 1
        last_item = {
          'home_goals' => league.forfait_goals,
          'guest_goals' => 0
        }
      elsif forfait == 2
        last_item = {
          'home_goals' => 0,
          'guest_goals' => league.forfait_goals
        }
      end
    end

    {
      home_goals: last_item['home_goals'],
      guest_goals: last_item['guest_goals'],
      home_goals_period: home_goals_period,
      guest_goals_period: guest_goals_period,
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
        #:not_started
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
      game_day_id: game_day_id,
      date: game_day.date,
      time: start_time,
      started: started,
      ended: ended,
      home_team_name: home_team_name,
      home_team_logo: home_team.logo_url,
      home_team_small_logo: home_team.logo_small_url,
      guest_team_name: guest_team_name,
      guest_team_logo: guest_team.logo_url,
      guest_team_small_logo: guest_team.logo_small_url,
      nominated_referee_string: nominated_referee_string,
      referees: referees,
      state: state
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
      penalty_ms1: 0,
      penalty_ms2: 0,
      penalty_ms3: 0,
      player_id: player_id,
      team_id: team.id,
      team_name: team.name
    }
  end

  def evaluate_scorer
    result = {}

    home_player_ids = [home_team_player_number.values].flatten.compact.sort
    home_player_ids.each do |p|
      result[p] = empty_score(p, home_team)
    end

    guest_player_ids = [guest_team_player_number.values].flatten.compact.sort
    guest_player_ids.each do |p|
      result[p] = empty_score(p, guest_team)
    end

    events.each do |event|
      if event['penalty_id'].present?
        # penalty?
        player_id = event['home_number'].present? ? home_team_player_number[event['home_number']] : guest_team_player_number[event['guest_number']]

        # register penalty for player
        result[player_id][penalty_mapping(event)] += 1 if player_id.present?  # skip if no player
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
      id: id,
      game_number: game_number,
      start_time: start_time,
      date: game_day.date,
      game_day: league.game_day_title_hash(game_day.number),
      audience: audience,
      home_team_name: home_team.name,
      guest_team_name: guest_team.name,
      home_team_logo: home_team.logo_url,
      home_team_small_logo: home_team.logo_small_url,
      guest_team_logo: guest_team.logo_url,
      guest_team_small_logo: guest_team.logo_small_url,
      live_stream_link: live_stream_link,
      events: formatted_events,
      players: players_with_position,
      started: started,
      ended: ended,
      result_string: result_string,
      result: result,
      league_id: league.id,
      league_name: league.name,
      league_short_name: league.short_name,
      game_operation_id: league.game_operation.id,
      game_operation_name: league.game_operation.name,
      game_operation_short_name: league.game_operation.short_name,
      period_titles: period_titles,
      arena: game_day.arena_id,
      arena_name: game_day.arena.name,
      arena_address: game_day.arena.address,
      arena_short: game_day.arena.schedule_item,
      nominated_referees: nominated_referee_string,
      referees: referees
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
      id: id,
      home: home_team.ticker_hash,
      guest: guest_team.ticker_hash,
      periods: 3,
      events: ticker_events,
      resultString: result_string,
      isLive: isLive,
      hasEnded: hasEnded,
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

    match_period = /(?<period>I+)|\/(?<period_number>\d{1})/.match timeout_string

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
      event_type: 'timeout',
      event_team: team,
      period: period,
      time: match['time'],
      sortkey: "#{period}-#{match['time'].rjust(5, "0")}"
    }
  end

  def formatted_events
    result = (events || []).map do |event|
      e = {
        event_type: nil,
        event_team: nil,
        period: event['period'],
        home_goals: event['home_goals'],
        guest_goals: event['guest_goals'],
        time: event['time'],
        sortkey: "#{event['period']}-#{event['time'].rjust(5, "0")}"
      }

      if event['home_number'].present?
        e[:event_team] = 'home'
        e[:number] = event['home_number']
        e[:assist] = event['home_assist'] if event['home_assist'].present?
      elsif event['guest_number'].present?

        e[:event_team] = 'guest'

        e[:number] = event['guest_number']
        e[:assist] = event['guest_assist'] if event['guest_assist'].present?
      else
        Sentry.capture_message("game: #{id}, event: #{event.to_json}")
        next
      end

      if event['penalty_code_id'] && event['penalty_code_id'].to_i != 23 # penalty_shot should be goal, not penalty.
        e[:event_type] = :penalty

        e[:penalty_type] = penalty_mapping(event)
        e[:penalty_type_string] = penalty_mapping_string(event)
        reason = penalty_reason(event)
        e[:penalty_reason] = reason['code']
        e[:penalty_reason_string] = reason['description']

      else
        e[:event_type] = :goal
        if event['penalty_code_id'].to_i != 23
          e[:goal_type] = :regular
          e[:goal_type_string] = 'Tor'
        elsif event['time'] == '70:00'
          e[:goal_type] = :penalty_shots
          e[:goal_type_string] = 'Entscheidung im Penalty-Schießen'
        else
          e[:goal_type] = :penalty_shot
          e[:goal_type_string] = 'Strafschuss'
        end
      end

      e
    end.compact

    (result + timeout_events).sort_by { |e| e[:sortkey] }
  end

  def period_titles
    case league.league_category_id.to_i
    when 1, 4, 102 # GF, Pokal GF, GF DM
      [
        { period: 1, title: '1. Drittel' },
        { period: 2, title: '2. Drittel' },
        { period: 3, title: '3. Drittel' },
        { period: 4, title: 'Verlängerung' },
        { period: 5, title: 'Penalty-Schießen' }
      ]
    else
      [
        { period: 1, title: '1. Hälfte' },
        { period: 2, title: '2. Hälfte' },
        { period: 3, title: 'Verlängerung' },
        { period: 4, title: 'Penalty-Schießen' }
      ]
    end
  end

  def self.start_end_games
    gds = GameDay.where date: Date.today
    games = gds.map(&:games).map(&:all).flatten
    t = Time.now

    filtered_games = games.select do |g|
      hour, minute = g.start_time.split(":")

      hour.to_i <= t.hour && minute.to_i < t.min
    end

    filtered_games.each do |g|
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
