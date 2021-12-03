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

  def players_with_position
    result = {}

    ['home', 'guest'].each do |team|
      result[team] = players[team].map do |player|
        player['position'] = player['goalkeeper'].present? && player['goalkeeper'] == true ? 'Tor' : ['Sturm', 'Center', 'Verteidigung'].sample
        player
      end
    end if players.present?

    result
  end

  def result
    return unless events.present?

    home_goals_period = [0,0,0,0]
    guest_goals_period = [0,0,0,0]

    last_item = nil
    home_previous_goals = 0
    guest_previous_goals = 0

    events.sort_by{ |e| e[:row] }.each do |e|
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

    {
      home_goals: last_item['home_goals'],
      guest_goals: last_item['guest_goals'],
      home_goals_period: home_goals_period,
      guest_goals_period: guest_goals_period,
      overtime: (overtime == true)
    }
  end

  def result_string
    res = result
    "#{res[:home_goals]}:#{res[:guest_goals]}#{res[:overtime] ? ' n.V' : ''}" if res
  end

  def state
    if record_created_at.present?
      if false
        :running
      elsif false
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
      home_team_name: home_team_name,
      home_team_logo: home_team.logo_url,
      home_team_small_logo: home_team.logo_small_url,
      guest_team_name: guest_team_name,
      guest_team_logo: guest_team.logo_url,
      guest_team_small_logo: guest_team.logo_small_url,
      nominated_referee_string: nominated_referee_string,
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
