class Game < ApplicationRecord
  belongs_to :home_team, class_name: "Team"
  belongs_to :guest_team, class_name: "Team"
  belongs_to :game_day

  def home_team_name
    home_team.name
  end

  def guest_team_name
    guest_team.name
  end

  def result
    last_item = nil
    events.sort_by{ |e| e[:row] }.each { |e| last_item = e if e["home_goals"].present? && e["guest_goals"].present? }

    "#{last_item["home_goals"]}:#{last_item["guest_goals"]}#{(overtime == true) ? ' n.V' : ''}" if last_item
  end
end
