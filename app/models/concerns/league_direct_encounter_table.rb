module LeagueDirectEncounterTable
  extend ActiveSupport::Concern

  def apply_direct_encounter_games!(results)
    source_league = League.find_by(id: league_id_direct_encounters)
    return unless source_league

    current_club_to_team = Team.where(id: results.keys).pluck(:club_id, :id).to_h
    source_team_to_club = source_league.teams.pluck(:id, :club_id).to_h
    affected_team_ids = Set.new

    source_league.games.each do |game|
      home_club = source_team_to_club[game.home_team_id]
      guest_club = source_team_to_club[game.guest_team_id]
      home_id = current_club_to_team[home_club]
      guest_id = current_club_to_team[guest_club]

      next unless home_id && guest_id
      next unless game.ended? && !game.result.nil?

      results[home_id][:games] += 1
      results[guest_id][:games] += 1
      results[home_id][:goals_scored] += game.result[:home_goals]
      results[home_id][:goals_received] += game.result[:guest_goals]
      results[guest_id][:goals_scored] += game.result[:guest_goals]
      results[guest_id][:goals_received] += game.result[:home_goals]

      if game.result[:home_goals] == game.result[:guest_goals]
        results[home_id][:draw] += 1
        results[guest_id][:draw] += 1
        results[home_id][:points] += draw_points if game.forfait != 3
        results[guest_id][:points] += draw_points if game.forfait != 3
      elsif game.result[:home_goals] > game.result[:guest_goals]
        if game.overtime
          results[home_id][:won_ot] += 1
          results[guest_id][:lost_ot] += 1
          results[home_id][:points] += won_overtime_points
          results[guest_id][:points] += lost_overtime_points
        else
          results[home_id][:won] += 1
          results[guest_id][:lost] += 1
          results[home_id][:points] += won_points
        end
      else
        if game.overtime
          results[guest_id][:won_ot] += 1
          results[home_id][:lost_ot] += 1
          results[guest_id][:points] += won_overtime_points
          results[home_id][:points] += lost_overtime_points
        else
          results[guest_id][:won] += 1
          results[home_id][:lost] += 1
          results[guest_id][:points] += won_points
        end
      end

      affected_team_ids << home_id << guest_id
    end

    affected_team_ids.each do |team_id|
      results[team_id][:goals_diff] = results[team_id][:goals_scored] - results[team_id][:goals_received]
      results[team_id][:has_direct_encounter_games] = true
    end
  end
end
