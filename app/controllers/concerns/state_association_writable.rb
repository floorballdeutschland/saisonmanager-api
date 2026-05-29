module StateAssociationWritable
  extend ActiveSupport::Concern

  private

  # Landesverbände, in die der aktuelle Nutzer als SBK schreiben darf
  # (eigene, gescopte LVs; globaler SBK `0` zählt hier nicht als Scope).
  def scoped_state_associations
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
