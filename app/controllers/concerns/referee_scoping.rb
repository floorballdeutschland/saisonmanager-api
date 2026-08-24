# Gemeinsames Verband-/Vereins-Scoping für Schiedsrichter. Stellt sicher, dass
# der Schiri-Admin und die Ansetzungs-/Verfügbarkeits-Ansichten denselben
# Referee-Bestand verwenden (globale Rolle inkl. Bundes-Spielbetrieb → alle
# Referees; sonst Vereine des LV ODER direkt zugeordneter Spielbetrieb).
module RefereeScoping
  extend ActiveSupport::Concern

  private

  # Der Berechtigungs-Hash entsteht nicht billig (u. a. League.current_season
  # .pluck) und wurde in der Ansetzung bis zu fünfmal je Anfrage neu gebaut –
  # zweistufige Autorisierung, Modus-Erkennung und Scope fragen ihn nacheinander.
  # Der Controller lebt genau eine Anfrage, deshalb hier gemerkt statt am Modell:
  # am User-Objekt gemerkt würde eine Rollenänderung im selben Prozess nicht mehr
  # gesehen (Tests setzen Berechtigungen um und lesen erneut).
  def permission_hash
    @permission_hash ||= current_user.permission_hash
  end

  def scope_to_permitted_referees(referees)
    ph = permission_hash
    return referees if ph[:admin].present?
    return referees if ph[:rsk].present? && ph[:rsk].include?(0)
    return referees if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

    # Rollen additiv: wer RSK/Ansetzer eines Verbands *und* VM eines Vereins
    # außerhalb dieses Verbands ist, verlor sonst die Schiris des eigenen
    # Vereins, weil die elsif-Kette am VM-Zweig vorbeilief.
    scopes = []
    if ph[:rsk].present? || ph[:ansetzer].present?
      go_ids = referee_scope_go_ids(ph)
      club_ids = lv_club_ids(go_ids)
      scopes << referees.where(club_id: club_ids).or(referees.where(game_operation_id: go_ids))
    end
    scopes << referees.where(club_id: ph[:vm]) if ph[:vm].present?

    scopes.reduce { |combined, scope| combined.or(scope) } || referees.none
  end

  # Rollen-Gate der Ansetzung: Admin, oder Ansetzer in (mind.) einem
  # Landesverband mit freigeschalteter Ansetzung (referee_assignment_enabled) –
  # analog zum Menü-Gating in User#permissions_items. FD/global (Spielbetrieb 0)
  # ist immer aktiv. Genutzt von der Ansetzung selbst und von der Pflege der
  # Vereins-Ausschlusslisten.
  def authorize_assigner!
    ph = permission_hash
    return if ph[:admin].present?
    return if ph[:ansetzer].present? && current_user.referee_assignment_active_for_ansetzer?(ph)

    render json: { error: 'Nicht berechtigt' }, status: :forbidden
  end

  # Engeres Gate fuer die Vereins-Ausschluesse: nur Admin und die bundesweite,
  # global gescopte Ansetzung von Floorball Deutschland. Ueber die Antraege
  # entscheidet diese eine Stelle, und dorthin geht auch die Antragsmail; ein
  # Landesverband soll sie weder sehen noch entscheiden. Die Ansetzung selbst
  # (Spiele, Verfuegbarkeiten) bleibt bei authorize_assigner! und damit
  # weiterhin bei den Landesverbaenden.
  def authorize_national_assigner!
    ph = permission_hash
    return if ph[:admin].present?
    return if ph[:ansetzer].present? && ph[:ansetzer].include?(0)

    render json: { error: 'Nicht berechtigt' }, status: :forbidden
  end

  def referee_scope_go_ids(perm_hash)
    ((perm_hash[:rsk] || []) + (perm_hash[:ansetzer] || []))
      .reject(&:zero?).uniq
  end

  # Konkrete (nicht auf global 0 kollabierte) Spielbetriebe der RSK-/Ansetzer-
  # Rollen des Nutzers – gelesen aus den Roh-Permissions. Anders als
  # referee_scope_go_ids behält dies die echte game_operation_id eines
  # nationalen Verbands (FD) bei, statt sie auf 0 zu mappen. Dadurch kann FD
  # einen eigenen, privaten Tag-Bestand pflegen. Leer für Admin bzw. für einen
  # explizit auf Spielbetrieb 0 gesetzten Nutzer (⇒ global, sieht/verwaltet alles).
  def tag_scope_go_ids
    current_user.permissions
                .select { |p| [3, 7].include?(p['user_group_id'].to_i) }
                .map { |p| p['game_operation_id'].to_i }
                .reject(&:zero?)
                .uniq
  end

  # Eigene Zustaendigkeit ueber Club.responsible_state_association_ids und nicht
  # ueber GameOperation#state_association_id: Ein Spielverbund wie SBK Ost haengt
  # an einem eigenen Landesverband, seine Vereine liegen aber in den
  # untergeordneten Landesverbaenden (Sachsen-Anhalt, Thueringen, Sachsen). Die
  # Spalte allein liefert nur die Wurzel, und die hatte auf Produktion am
  # 24.08.2026 einen Verein und keinen einzigen Schiedsrichter -- der RSK des
  # Verbunds sah damit ausschliesslich die Schiris einer fremden Vereins-Freigabe
  # und keinen aus dem eigenen Bestand (2028 fehlten). Dieselbe Kette liest die
  # Vereinsliste (Club.home_clubs_of) und die Rollenvergabe schon; nur das
  # Schiri-Scoping war beim Umstieg auf den Verbandsbaum stehen geblieben.
  def lv_club_ids(go_ids)
    own_sa_ids = Club.responsible_state_association_ids(go_ids)
    # Vereins-Freigaben: Hat ein anderer LV seine Vereine an einen dieser
    # Spielbetriebe freigegeben (StateAssociationRelease), gehören dessen Schiris
    # ebenfalls zum ansetzbaren Bestand (analog Club.admin_user_clubs).
    released_sa_ids = StateAssociationRelease.current_season
                                             .where(recipient_game_operation_id: go_ids)
                                             .pluck(:grantor_state_association_id)
    Club.where(state_association_id: (own_sa_ids + released_sa_ids).uniq).pluck(:id)
  end
end
