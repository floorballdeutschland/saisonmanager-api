module StateAssociationWritable
  extend ActiveSupport::Concern

  private

  # Globaler Admin oder ein global gescopter SBK (`ph[:sbk]` enthält `0`, z. B.
  # der SBK von Floorball Deutschland) darf alle Landesverbände verwalten.
  def global_state_association_manager?
    ph = current_user.permission_hash
    ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))
  end

  # Strenger als #global_state_association_manager?: WIRKLICH bundesweit, also
  # `0` im Scope. Die Methode oben lässt jede Admin-Rolle durch, auch eine regional
  # gescopte (`permission_hash` hebt `ph[:admin]` nur dann auf `[0]`, wenn sie alle
  # Spielbetriebe trägt), und ein regional gescopter Admin ist ein bestehender
  # Zustand -- der Bestandstest „Admin darf jeden Landesverband bearbeiten" legt
  # genau so einen an.
  #
  # Für Felder, die die Zuständigkeit für Vereine verschieben, genügt das nicht:
  # Wer `parent_id` setzt, hängt den ganzen Teilbaum eines fremden Verbands unter
  # den eigenen Verbund und zieht damit `:update_club`, `:update_player`, die
  # Rollenvergabe, Transfers, Lizenzdokumente und Spielersperren für alle Vereine
  # darunter zu sich. Der bisherige Verband merkt es an einer kürzeren Liste.
  def nationwide_state_association_manager?
    ph = current_user.permission_hash
    Array(ph[:admin]).include?(0) || Array(ph[:sbk]).include?(0)
  end

  # Landesverbände, in die der aktuelle Nutzer als SBK schreiben darf.
  # Globaler Admin / globaler SBK: alle LVs; regionaler SBK: den eigenen und
  # dessen untergeordnete.
  #
  # Der Teilbaum, nicht nur der eigene Verband: Wer für die Vereine eines
  # untergeordneten Verbands zuständig ist (Club#main_game_operation_id hebt auf
  # die Wurzel), muss auch dessen Verbandsdaten pflegen können. Sonst entsteht
  # genau der Bruch, den diese Umstellung beseitigt, nur an der Gegenstelle:
  # Der Floorballverband Schleswig-Holstein verwaltet nach dem Datenlauf die
  # sechs Hamburger Vereine, bekäme auf den Landesverband Hamburg aber 403 und
  # könnte dort weder den Zuständigkeitsbereich (#468) noch das Logo pflegen
  # noch eine Vereins-Freigabe zurücknehmen. Das könnte nur die Bundesebene.
  def scoped_state_associations
    return StateAssociation.all if global_state_association_manager?

    ph = current_user.permission_hash
    go_ids = (ph[:sbk] || []).reject(&:zero?).uniq
    sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact
    StateAssociation.where(id: StateAssociation.ids_under(sa_ids.map { |id| StateAssociation.root_id(id) }.compact))
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
