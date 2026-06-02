module StateAssociationWritable
  extend ActiveSupport::Concern

  private

  # Globaler Admin oder ein global gescopter SBK (`ph[:sbk]` enthält `0`, z. B.
  # der SBK von Floorball Deutschland) darf alle Landesverbände verwalten.
  def global_state_association_manager?
    ph = current_user.permission_hash
    ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))
  end

  # Landesverbände, in die der aktuelle Nutzer als SBK schreiben darf.
  # Globaler Admin / globaler SBK: alle LVs; regionaler SBK: nur die eigenen
  # (gescopten) LVs.
  def scoped_state_associations
    return StateAssociation.all if global_state_association_manager?

    ph = current_user.permission_hash
    go_ids = (ph[:sbk] || []).reject(&:zero?).uniq
    sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact
    StateAssociation.where(id: sa_ids)
  end

  # Schreibzugriff auf @state_association: globaler Admin überall, SBK
  # ausschließlich auf den eigenen (gescopten) Landesverband. Setzt voraus,
  # dass @state_association vorher (z. B. via set_state_association) geladen ist.
  def authorize_state_association_write!
    ph = current_user.permission_hash
    return if ph[:admin].present?
    return if ph[:sbk].present? && scoped_state_associations.exists?(@state_association.id)

    render json: { error: 'Nicht berechtigt' }, status: :forbidden
  end
end
