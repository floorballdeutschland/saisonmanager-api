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
end
