# frozen_string_literal: true

# Team-IDs, die die angemeldete Person verantwortet: als Teammanager direkt
# (permission_hash[:tm]) oder als Vereinsmanager über alle Teams der eigenen
# Vereine (permission_hash[:vm]). Von den team-seitigen Schiri-Feedback-
# Controllern geteilt.
module ManagedTeams
  extend ActiveSupport::Concern

  private

  def managed_team_ids
    @managed_team_ids ||= begin
      ids = tm_team_ids.dup
      ids += Team.where(club_id: managed_club_ids).pluck(:id) if managed_club_ids.present?
      ids.uniq
    end
  end

  def tm_team_ids
    @tm_team_ids ||= Array(current_user.permission_hash[:tm]).map(&:to_i)
  end

  def managed_club_ids
    @managed_club_ids ||= Array(current_user.permission_hash[:vm]).map(&:to_i)
  end
end
