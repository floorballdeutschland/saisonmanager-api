class Game < ApplicationRecord
  belongs_to :home_team, class_name: "Team"
  belongs_to :guest_team, class_name: "Team"
  belongs_to :game_day

  EMPTY_SCORE = {
    games: 1,
    goals: 0,
    assists: 0,
    penalty_2: 0,
    penalty_5: 0,
    penalty_10: 0,
    penalty_ms: 0
  }


  def home_team_name
    home_team.name
  end

  def home_team_player_number
    players["home"].map { |p| { p['trikot_number'] => p['player_id'] } }.reduce(&:merge)
  end

  def guest_team_name
    guest_team.name
  end

  def guest_team_player_number
    players["guest"].map { |p| { p['trikot_number'] => p['player_id'] } }.reduce(&:merge)
  end

  def result
    return unless events.present?

    last_item = nil
    events.sort_by{ |e| e[:row] }.each { |e| last_item = e if e["home_goals"].present? && e["guest_goals"].present? }

    {
      home_goals: last_item["home_goals"],
      guest_goals: last_item["guest_goals"],
      home_goals_period: [0,0,0],
      guest_goals_period: [1,1,1],
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
      guest_team_name: guest_team_name,
      nominated_referee_string: nominated_referee_string,
      state: state
    }

    item[:result_string] = result_string if record_created_at.present?

    item
  end

  def evaluate_scorer
    result = {}

    player_ids = [home_team_player_number.values, guest_team_player_number.values].flatten.sort
    player_ids.each do |p|
      result[p] = EMPTY_SCORE
    end

    events.each do |event|
      if event['penalty_id'].present?
        player_id = event['home_number'].present? ? guest_team_player_number[event['home_number']]  : guest_team_player_number[event['guest_number']]
        puts player_id
        # skip if no player
        # register penalty for player

      end

      #penalty
      #{"1": {"name": "2'", "description": null}, "2": {"name": "5'", "description": null}, "3": {"name": "10'", "description": null}, "4": {"name": "M I", "description": null}, "5": {"name": "M II", "description": null}, "6": {"name": "M III", "description": null}}

    end

    result
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
      if e['penalty_code_id']
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
      if !g.started? && g.players.present? && g.players["home"].present? && g.players["guest"].present?
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
