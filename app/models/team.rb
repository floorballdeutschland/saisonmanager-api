class Team < ApplicationRecord
  def tasks
    Task.where("home_team = ? OR guest_team = ?", self.id, self.id)
  end
end
