# Gemeinsames Verband-/Vereins-Scoping für Schiedsrichter. Stellt sicher, dass
# der Schiri-Admin und die Ansetzungs-/Verfügbarkeits-Ansichten denselben
# Referee-Bestand verwenden (globale Rolle inkl. Bundes-Spielbetrieb → alle
# Referees; sonst Vereine des LV ODER direkt zugeordneter Spielbetrieb).
module RefereeScoping
  extend ActiveSupport::Concern

  private

  def scope_to_permitted_referees(referees)
    ph = current_user.permission_hash
    return referees if ph[:admin].present?
    return referees if ph[:rsk].present? && ph[:rsk].include?(0)
    return referees if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

    if ph[:rsk].present? || ph[:ansetzer].present?
      go_ids = referee_scope_go_ids(ph)
      club_ids = lv_club_ids(go_ids)
      referees.where(club_id: club_ids).or(referees.where(game_operation_id: go_ids))
    elsif ph[:vm].present?
      referees.where(club_id: ph[:vm])
    else
      referees.none
    end
  end

  def referee_scope_go_ids(perm_hash)
    ((perm_hash[:rsk] || []) + (perm_hash[:ansetzer] || []))
      .reject(&:zero?).uniq
  end

  def lv_club_ids(go_ids)
    own_sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact
    # Vereins-Freigaben: Hat ein anderer LV seine Vereine an einen dieser
    # Spielbetriebe freigegeben (StateAssociationRelease), gehören dessen Schiris
    # ebenfalls zum ansetzbaren Bestand (analog Club.admin_user_clubs).
    released_sa_ids = StateAssociationRelease.current_season
                                             .where(recipient_game_operation_id: go_ids)
                                             .pluck(:grantor_state_association_id)
    Club.where(state_association_id: (own_sa_ids + released_sa_ids).uniq).pluck(:id)
  end
end
