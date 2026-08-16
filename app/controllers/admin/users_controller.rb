module Admin
  class UsersController < ApplicationController
    # Rollen mit Verbund-Scope (SBK, RSK, Ansetzer) bzw. Vereins-Scope (VM, TM).
    GO_SCOPED_ROLES = [2, 3, 7].freeze
    CLUB_SCOPED_ROLES = [4, 5].freeze
    ADMIN_ROLE = 1

    before_action :authorize_user_management!
    before_action :set_managed_user, only: %i[show update destroy trigger_password_reset add_role remove_role archive unarchive]
    before_action :require_admin_for_elevated_target!,
                  only: %i[update destroy trigger_password_reset archive unarchive add_role remove_role]

    # GET /api/v2/admin/users
    def index
      users = scoped_users.order(:last_name, :first_name, :user_name).to_a
      lookups = assignment_lookups(users)
      render json: users.map { |u| user_json(u, lookups: lookups) }
    end

    # GET /api/v2/admin/users/:id
    def show
      render json: user_json(@managed_user, full: true)
    end

    # PATCH /api/v2/admin/users/:id
    def update
      ph = current_user.permission_hash
      updates = {}

      # apply_club_change / apply_go_change berechnen :permissions aus dem
      # unveränderten Objekt und würden ein im selben Request geändertes :role
      # wieder überschreiben (stiller Fehlschreib mit 200). Die Benutzermaske
      # kombiniert das nicht, deshalb hier ablehnen statt still falsch zu
      # speichern.
      if params.key?(:role) && (params.key?(:club_id) || params.key?(:game_operation_id))
        return render json: { error: 'Rolle und Zuweisung bitte getrennt speichern' },
                      status: :unprocessable_entity
      end

      updates[:email] = params[:email] if params.key?(:email)

      if params.key?(:teams)
        # Manager ohne VM-/SBK-/Admin-Scope (z. B. reiner RSK) darf keine Teams
        # zuweisen – sonst ließen sich beliebige Teams an ein Konto hängen.
        unless ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
          return render json: { error: 'Nicht berechtigt, Teams zuzuweisen' }, status: :forbidden
        end

        # Zielverein des Kontos: Die Rollen-Berechtigung ist maßgeblich (die
        # Spalte kann davon abweichen), ein Vereinswechsel im selben Request
        # gewinnt. Ohne Verein am Konto bleibt es beim Scope des Handelnden.
        target_club_id = params[:club_id].presence&.to_i || tm_club_id(@managed_user)
        result = resolve_team_ids(params[:teams], ph, target_club_id: target_club_id)
        return render json: { error: result[:error] }, status: result[:status] if result[:error]

        updates[:teams] = result[:team_ids]
      end

      if params.key?(:role)
        result = apply_role_change(@managed_user, params[:role].to_i, ph)
        return render json: { error: result[:error] }, status: result[:status] if result[:error]

        updates[:permissions] = result[:permissions]
      end

      if params.key?(:club_id)
        result = apply_club_change(@managed_user, params[:club_id].to_i, ph)
        return render json: { error: result[:error] }, status: result[:status] if result[:error]

        club_updates = result[:updates]
        # Ein explizit mitgesendetes teams gewinnt gegen das implizite Leeren
        # beim Vereinswechsel. Sonst verlöre ein Request, der beides trägt, die
        # Zuweisung wieder, weil merge! nach dem teams-Zweig läuft.
        club_updates = club_updates.except(:teams) if params.key?(:teams)
        updates.merge!(club_updates)
      end

      if params.key?(:game_operation_id)
        result = apply_go_change(@managed_user, params[:game_operation_id].to_i)
        return render json: { error: result[:error] }, status: result[:status] if result[:error]

        updates.merge!(result[:updates])
      end

      if @managed_user.update(updates)
        render json: user_json(@managed_user.reload, full: true)
      else
        render json: { errors: @managed_user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # POST /api/v2/admin/users
    def create
      ph = current_user.permission_hash
      role_id = params.dig(:role, :user_group_id).to_i
      club_id = params.dig(:role, :club_id).to_i.nonzero?
      go_id   = params.dig(:role, :game_operation_id).to_i.nonzero?

      # Der VM-Zweig legt ausschließlich vereinsgebundene Konten an (er baut die
      # Berechtigung selbst und hängt keinen Verbund daran). Wer neben VM auch
      # RSK ist, fällt für die übrigen Rollen deshalb in den allgemeinen Zweig
      # unten, statt hier mit „VM darf nur TM- oder VM-Nutzer anlegen"
      # abgewiesen zu werden.
      if ph[:vm].present? && !ph[:admin].present? && !ph[:sbk].present? &&
         (ph[:rsk].blank? || CLUB_SCOPED_ROLES.include?(role_id))
        return render json: { error: 'VM darf nur TM- oder VM-Nutzer anlegen' }, status: :forbidden unless CLUB_SCOPED_ROLES.include?(role_id)
        return render json: { error: 'Verein nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden unless club_id && ph[:vm].include?(club_id)

        perm = { 'user_group_id' => role_id }
        perm['club_id'] = club_id.to_s if role_id == 4
        user = User.new(user_create_params)
        user.password    = SecureRandom.hex(12)
        user.club_id     = club_id
        user.permissions = [perm]

        if (result = team_assignment_error(user, role_id, ph, club_id))
          return render json: { error: result[:error] }, status: result[:status]
        end

        if user.save
          # Konto steht, unabhängig davon, ob die Willkommensmail rausging – ein
          # Fehlschlag darf das Anlegen nicht nachträglich als Fehler ausgeben,
          # sonst legt der Aufrufer dasselbe Konto erneut an. Wie bei der
          # Schiri-Kontoanlage sagt email_sent, was passiert ist.
          email_sent = user.send_reset_information
          return render json: user_json(user).merge(email_sent:), status: :created
        else
          return render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      unless ph[:admin].present? || ph[:sbk].present? || ph[:rsk].present?
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      unless current_user.assignable_role_ids(ph).include?(role_id)
        return render json: { error: 'Diese Rolle darf nicht vergeben werden' }, status: :forbidden
      end

      if GO_SCOPED_ROLES.include?(role_id) && !go_id
        return render json: { error: 'Verbund muss für SBK/RSK/Ansetzer angegeben werden' }, status: :unprocessable_entity
      end

      # SBK und RSK vergeben Rollen nur auf eigener Ebene oder darunter: Ein
      # verbandsgebundenes Konto bleibt auf die eigenen Spielbetriebe begrenzt,
      # ein national gescoptes (FD) deckt über permission_hash alle ab.
      unless permission_assignable?({ 'user_group_id' => role_id, 'game_operation_id' => go_id })
        return render json: { error: 'Verbund nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden
      end

      if club_id && !ph[:admin].present?
        # Gleiche Quelle wie das Vereins-Dropdown (GET admin/clubs/role_assignable),
        # damit dort nichts angeboten wird, was hier abgelehnt wird.
        allowed = Club.role_assignable_for(current_user, include_deactivated: true).pluck(:id)
        return render json: { error: 'Verein nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden unless allowed.include?(club_id)
      end

      perm = { 'user_group_id' => role_id }
      perm['club_id']           = club_id.to_s if club_id
      perm['game_operation_id'] = go_id.to_s   if go_id

      user = User.new(user_create_params)
      user.password    = SecureRandom.hex(12)
      user.club_id     = club_id if club_id
      user.permissions = [perm]

      # Beide Anlage-Zweige (VM oben, Admin/SBK hier) müssen teams übernehmen:
      # Eine verworfene Zuweisung sperrt das Konto aus.
      if (result = team_assignment_error(user, role_id, ph, club_id))
        return render json: { error: result[:error] }, status: result[:status]
      end

      if user.save
        email_sent = user.send_reset_information
        render json: user_json(user).merge(email_sent:), status: :created
      else
        render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/users/:id
    def destroy
      return render json: { error: 'Nur Admins können Benutzer löschen' }, status: :forbidden unless current_user.permission_hash[:admin].present?
      return render json: { error: 'Eigenes Konto kann nicht gelöscht werden' }, status: :forbidden if @managed_user.id == current_user.id

      @managed_user.destroy!
      head :no_content
    rescue ActiveRecord::InvalidForeignKey
      render json: { error: 'Benutzer kann nicht gelöscht werden: Es existieren noch verknüpfte Einträge (z.B. Spielberichte oder Dokumente).' },
             status: :unprocessable_entity
    end

    # POST /api/v2/admin/users/:id/archive
    # Ersetzt das frühere Hart-Löschen bzw. den active-Schalter: Das Konto bleibt
    # mit allen Verknüpfungen erhalten, kann sich aber nicht mehr einloggen.
    # Berechtigung wie Bearbeiten (authorize_user_management! + Scope + Elevated-Check).
    def archive
      return render json: { error: 'Eigenes Konto kann nicht archiviert werden' }, status: :forbidden if @managed_user.id == current_user.id
      return render json: { error: 'Benutzer ist bereits archiviert' }, status: :unprocessable_entity if @managed_user.archived?

      @managed_user.archive!(current_user.id)
      render json: user_json(@managed_user.reload, full: true)
    end

    # POST /api/v2/admin/users/:id/unarchive
    def unarchive
      return render json: { error: 'Benutzer ist nicht archiviert' }, status: :unprocessable_entity unless @managed_user.archived?

      @managed_user.unarchive!
      render json: user_json(@managed_user.reload, full: true)
    end

    # POST /api/v2/admin/users/:id/trigger_password_reset
    def trigger_password_reset
      # Hier hat jemand den Versand ausdrücklich angestoßen und wartet auf die
      # Rückmeldung – ein stiller Fehlschlag würde eine Mail versprechen, die
      # nie ankommt.
      if @managed_user.send_reset_information
        render json: { success: true }
      else
        render json: { success: false, message: 'Die Reset-Mail konnte nicht versendet werden. Bitte später erneut versuchen.' },
               status: :bad_gateway
      end
    end

    # POST /api/v2/admin/users/:id/add_role
    # Fügt einem Konto eine weitere Rolle hinzu (Mehrfachrollen, z. B. RSK + Ansetzer).
    # Admin, SBK und RSK im Rahmen ihres Scopes (User::ASSIGNABLE_ROLE_IDS);
    # die Admin-Rolle (1) wird hierüber bewusst nie vergeben.
    def add_role
      ph = current_user.permission_hash
      return render json: { error: 'Nicht berechtigt, Rollen zu verwalten' }, status: :forbidden unless manage_roles_allowed?(ph)
      return render json: { error: 'Eigene Rollen können nicht geändert werden' }, status: :forbidden if @managed_user.id == current_user.id

      role_id = params[:user_group_id].to_i
      go_id   = params[:game_operation_id].to_i.nonzero?
      club_id = params[:club_id].to_i.nonzero?

      return render json: { error: 'Ungültige Rolle' }, status: :unprocessable_entity unless [2, 3, 4, 5, 7].include?(role_id)

      unless current_user.assignable_role_ids(ph).include?(role_id)
        return render json: { error: 'Diese Rolle darf nicht vergeben werden' }, status: :forbidden
      end

      if @managed_user.permissions.any? { |p| p['user_group_id'].to_i == User::REFEREE_ROLE_ID }
        return render json: { error: 'Ein Schiedsrichter-Konto kann keine weitere Rolle erhalten' },
                      status: :unprocessable_entity
      end

      if GO_SCOPED_ROLES.include?(role_id)
        return render json: { error: 'Verbund erforderlich' }, status: :unprocessable_entity unless go_id
        return render json: { error: 'Ungültiger Verbund' }, status: :unprocessable_entity unless GameOperation.exists?(go_id)
      end

      if CLUB_SCOPED_ROLES.include?(role_id)
        return render json: { error: 'Verein erforderlich' }, status: :unprocessable_entity unless club_id
        return render json: { error: 'Ungültiger Verein' }, status: :unprocessable_entity unless Club.exists?(club_id)
      end

      perm = { 'user_group_id' => role_id }
      perm['game_operation_id'] = go_id.to_s if go_id && GO_SCOPED_ROLES.include?(role_id)
      perm['club_id'] = club_id.to_s if club_id && CLUB_SCOPED_ROLES.include?(role_id)

      unless permission_assignable?(perm)
        return render json: { error: 'Rolle nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden
      end

      if @managed_user.permissions.any? { |p| same_permission?(p, perm) }
        return render json: { error: 'Diese Rolle ist bereits vorhanden' }, status: :unprocessable_entity
      end

      updates = { permissions: @managed_user.permissions + [perm] }
      # club_id-Feld am Konto setzen, wenn (noch) keiner gesetzt ist und eine VM-Rolle dazukommt.
      updates[:club_id] = club_id if role_id == 4 && @managed_user.club_id.blank?

      if @managed_user.update(updates)
        render json: user_json(@managed_user.reload, full: true)
      else
        render json: { errors: @managed_user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/users/:id/remove_role
    def remove_role
      ph = current_user.permission_hash
      return render json: { error: 'Nicht berechtigt, Rollen zu verwalten' }, status: :forbidden unless manage_roles_allowed?(ph)
      return render json: { error: 'Eigene Rollen können nicht geändert werden' }, status: :forbidden if @managed_user.id == current_user.id

      target = {
        'user_group_id' => params[:user_group_id].to_i,
        'game_operation_id' => params[:game_operation_id].to_i.nonzero?&.to_s,
        'club_id' => params[:club_id].to_i.nonzero?&.to_s
      }

      removed = @managed_user.permissions.select { |p| same_permission?(p, target) }
      remaining = @managed_user.permissions.reject { |p| same_permission?(p, target) }

      return render json: { error: 'Rolle nicht gefunden' }, status: :unprocessable_entity if removed.empty?
      return render json: { error: 'Mindestens eine Rolle muss bestehen bleiben' }, status: :unprocessable_entity if remaining.empty?

      # Entziehen ist an denselben Scope gebunden wie Vergeben – sonst könnte
      # eine RSK einem Konto die SBK-Rolle nehmen, die sie selbst nie vergeben
      # dürfte.
      unless removed.all? { |p| permission_assignable?(p) }
        return render json: { error: 'Rolle nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden
      end

      if @managed_user.update(permissions: remaining)
        render json: user_json(@managed_user.reload, full: true)
      else
        render json: { errors: @managed_user.errors.full_messages }, status: :unprocessable_entity
      end
    end

    private

    # Gleiche Rolle = gleiche Gruppe und gleicher Scope (Verbund/Verein),
    # leere/fehlende Scope-Werte einheitlich als '' verglichen.
    def same_permission?(a, b)
      a['user_group_id'].to_i == b['user_group_id'].to_i &&
        a['game_operation_id'].to_s == b['game_operation_id'].to_s &&
        a['club_id'].to_s == b['club_id'].to_s
    end

    def scoped_users
      ph = current_user.permission_hash
      if ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0)) ||
         (ph[:rsk].present? && ph[:rsk].include?(0))
        return User.all
      end

      # Rollen additiv: ein Nutzer mit SBK-/RSK- *und* VM-Rolle verlor sonst die
      # Konten des eigenen Vereins, sobald dieser außerhalb des eigenen
      # Spielbetriebs liegt. Die Schreibrechte bleiben davon unberührt, dafür
      # sorgt weiterhin require_admin_for_elevated_target!.
      ids = []
      if ph[:sbk].present? || ph[:rsk].present?
        go_ids = (ph[:sbk] || []) + (ph[:rsk] || [])
        ids += User.where(club_id: derive_club_ids_for_go(go_ids)).pluck(:id)
        ids += lv_scoped_user_ids(go_ids)
      end
      ids += User.where(club_id: ph[:vm]).pluck(:id) if ph[:vm].present?

      User.where(id: (ids + [current_user.id]).uniq)
    end

    def lv_scoped_user_ids(go_ids)
      if go_ids.include?(0)
        User.where(
          "permissions @> '[{\"user_group_id\": 2}]' OR permissions @> '[{\"user_group_id\": 3}]' " \
          "OR permissions @> '[{\"user_group_id\": 7}]'"
        ).pluck(:id)
      else
        conditions = go_ids.flat_map { |go_id|
          gid = go_id.to_i
          [2, 3, 7].flat_map do |group|
            [
              "permissions @> '[{\"user_group_id\": #{group}, \"game_operation_id\": \"#{gid}\"}]'",
              "permissions @> '[{\"user_group_id\": #{group}, \"game_operation_id\": #{gid}}]'"
            ]
          end
        }.join(' OR ')
        User.where(conditions).pluck(:id)
      end
    end

    def set_managed_user
      @managed_user = scoped_users.find_by(id: params[:id])
      render json: { error: 'Nicht gefunden' }, status: :not_found unless @managed_user
    end

    def authorize_user_management!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present? || ph[:rsk].present? || ph[:vm].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def require_admin_for_elevated_target!
      # Reine Team-Zuweisung (params[:teams]) ist bereits im update-Action-Branch
      # feldspezifisch abgesichert und birgt kein Übernahme-Risiko, sonst
      # würde z.B. ein TM mit zusätzlicher RSK-Rolle jede Team-Zuweisung blocken.
      return if action_name == 'update' && (params.keys.map(&:to_sym) & %i[email role club_id game_operation_id]).empty?

      ph = current_user.permission_hash
      return if ph[:admin].present?

      target_perms = @managed_user.permissions

      # Admin-Konten bleiben Admins vorbehalten: Über E-Mail-Änderung +
      # Passwort-Reset ließe sich ein solches Konto sonst übernehmen.
      if target_perms.any? { |p| p['user_group_id'].to_i == ADMIN_ROLE }
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      # Sonst darf verwalten, wer jede Rolle des Zielkontos im eigenen Scope
      # auch selbst vergeben dürfte. Damit verwaltet eine reine RSK genau die
      # RSK-/Ansetzer-Konten des eigenen Verbands, aber weiterhin keine VM-/TM-
      # oder SBK-Konten (Rechteausweitung quer zur Rolle). Schiedsrichter-
      # Selfservice-Konten (6) tragen keinen Verwaltungs-Scope und bleiben für
      # alle Verwaltungsrollen erreichbar.
      return if target_perms.all? { |p| p['user_group_id'].to_i == User::REFEREE_ROLE_ID || permission_assignable?(p) }

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def manage_roles_allowed?(perm_hash)
      perm_hash[:admin].present? || perm_hash[:sbk].present? || perm_hash[:rsk].present?
    end

    # Darf der/die Handelnde diesen Rollen-Eintrag vergeben bzw. entziehen?
    # Prüft die Rolle selbst und ihren Scope (Verbund bei SBK/RSK/Ansetzer,
    # Verein bei VM/TM).
    # permission_hash löst die Rollen gegen die DB auf (Saison-Teams,
    # national-Flag der Verbünde). Die Scope-Prüfung unten läuft pro
    # Rollen-Eintrag des Zielkontos, deshalb einmal pro Request auflösen.
    def current_permission_hash
      @current_permission_hash ||= current_user.permission_hash
    end

    def permission_assignable?(perm)
      ph = current_permission_hash
      role_id = perm['user_group_id'].to_i
      return false unless current_user.assignable_role_ids(ph).include?(role_id)

      if GO_SCOPED_ROLES.include?(role_id)
        allowed_gos = assignable_go_ids_for_role(ph, role_id)
        return false unless allowed_gos.nil? || allowed_gos.include?(perm['game_operation_id'].to_i)
      end

      if CLUB_SCOPED_ROLES.include?(role_id) && perm['club_id'].present?
        allowed_clubs = assignable_club_ids
        return false unless allowed_clubs.nil? || allowed_clubs.include?(perm['club_id'].to_i)
      end

      true
    end

    # Verbünde, in denen die Rolle vergeben werden darf; nil = unbeschränkt
    # (Admin sowie national/global gescopte SBK bzw. RSK). Nur die eigenen
    # Rollen zählen, die diese Ziel-Rolle überhaupt vergeben dürfen: Eine RSK
    # bringt keinen Scope für die SBK-Rolle mit.
    def assignable_go_ids_for_role(perm_hash, role_id)
      return nil if perm_hash[:admin].present?

      go_ids = []
      %i[sbk rsk].each do |own_role|
        next unless User::ASSIGNABLE_ROLE_IDS[own_role].include?(role_id)

        go_ids += Array(perm_hash[own_role])
      end
      return nil if go_ids.include?(0)

      go_ids.uniq
    end

    # Vereine, für die vereinsgebundene Rollen (VM/TM) vergeben werden dürfen;
    # nil = unbeschränkt. Gleiche Quelle wie das Vereins-Dropdown der Maske.
    def assignable_club_ids
      ph = current_permission_hash
      return nil if ph[:admin].present? || ph[:sbk]&.include?(0)

      @assignable_club_ids ||= Club.role_assignable_for(current_user, include_deactivated: true).pluck(:id)
    end

    def require_sbk_or_admin!
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end

    def user_create_params
      params.require(:user).permit(:user_name, :first_name, :last_name, :email)
    end

    def apply_role_change(user, new_role, ph)
      return { error: 'Kann eigene Rolle nicht ändern', status: :forbidden } if user.id == current_user.id
      return { error: 'Ungültige Rolle', status: :unprocessable_entity } unless [4, 5].include?(new_role)

      current_roles = user.permissions.map { |p| p['user_group_id'].to_i }
      current_vm_tm = current_roles.any? { |r| [4, 5].include?(r) }
      return { error: 'Benutzer hat keine VM/TM-Rolle', status: :unprocessable_entity } unless current_vm_tm

      if ph[:vm].present? && !ph[:admin].present? && !ph[:sbk].present?
        club_id = ph[:vm].find { |cid| cid == user.club_id }
        return { error: 'Nicht berechtigt für diesen Club', status: :forbidden } unless club_id

        new_perms = user.permissions.map do |p|
          if [4, 5].include?(p['user_group_id'].to_i)
            entry = { 'user_group_id' => new_role }
            entry['club_id'] = club_id.to_s if new_role == 4
            entry
          else
            p
          end
        end
      elsif ph[:admin].present? || ph[:sbk].present?
        new_perms = user.permissions.map do |p|
          if [4, 5].include?(p['user_group_id'].to_i)
            entry = { 'user_group_id' => new_role }
            entry['club_id'] = p['club_id'] if new_role == 4 && p['club_id'].present?
            entry['club_id'] = user.club_id.to_s if new_role == 4 && p['club_id'].blank? && user.club_id.present?
            entry
          else
            p
          end
        end
      else
        return { error: 'Nicht berechtigt', status: :forbidden }
      end

      { permissions: new_perms }
    end

    def apply_club_change(user, new_club_id, ph)
      return { error: 'Kann eigene Zuweisung nicht ändern', status: :forbidden } if user.id == current_user.id

      return { error: 'Ungültiger Verein', status: :unprocessable_entity } unless Club.exists?(new_club_id)

      unless ph[:admin].present? || ph[:sbk]&.include?(0) ||
             (ph[:sbk].present? && derive_club_ids_for_go(ph[:sbk]).include?(new_club_id)) ||
             (ph[:vm].present? && ph[:vm].include?(new_club_id))
        return { error: 'Nicht berechtigt', status: :forbidden }
      end

      role_ids = user.permissions.map { |p| p['user_group_id'].to_i }
      unless role_ids.any? { |id| [4, 5].include?(id) }
        return { error: 'Benutzer hat keine VM/TM-Rolle', status: :unprocessable_entity }
      end

      vm_entries = user.permissions.count { |p| p['user_group_id'].to_i == 4 }
      if vm_entries > 1
        return { error: 'Benutzer verwaltet mehrere Vereine – Einzelzuweisung nicht möglich', status: :unprocessable_entity }
      end

      updates = { club_id: new_club_id }

      if role_ids.include?(4)
        updates[:permissions] = user.permissions.map do |p|
          p['user_group_id'].to_i == 4 ? p.merge('club_id' => new_club_id.to_s) : p
        end
      end

      # Team-Zuweisungen hängen am Verein und werden beim echten Vereinswechsel
      # hinfällig. Bei unverändertem Verein dürfen sie nicht verworfen werden:
      # Requests der Benutzermaske tragen club_id auch dann, wenn der Verein
      # gleich bleibt, und löschten so die vorhandene Zuweisung. Das Konto war
      # danach ausgesperrt, ohne dass eine Meldung darauf hinwies.
      #
      # Verglichen wird gegen die Rollen-Berechtigung UND die Spalte: Beide
      # können auseinanderlaufen (create schreibt perm['club_id'] für jede
      # Rolle, der Zweig oben zieht sie nur für VM mit), und die Maske belegt
      # ihr Auswahlfeld aus der Berechtigung. Nur wenn der neue Verein zu keinem
      # der beiden passt, ist es ein echter Wechsel.
      if role_ids.include?(5) && ![tm_club_id(user), user.club_id].compact.include?(new_club_id)
        updates[:teams] = []
      end

      # Die TM-Berechtigung trägt den Verein mit (create schreibt ihn dort),
      # sonst bliebe sie nach einem Wechsel auf dem alten Verein stehen und
      # jeder weitere Speichervorgang der Maske sähe erneut einen Wechsel.
      if role_ids.include?(5)
        updates[:permissions] = (updates[:permissions] || user.permissions).map do |p|
          p['user_group_id'].to_i == 5 && p['club_id'].present? ? p.merge('club_id' => new_club_id.to_s) : p
        end
      end

      { updates: updates }
    end

    # Verein aus der TM-Rollen-Berechtigung. Für TM-Konten ist das die Quelle,
    # aus der die Benutzermaske ihr Vereins-Auswahlfeld belegt; sie kann von der
    # Spalte users.club_id abweichen.
    def tm_club_id(user)
      user.permissions.find { |p| p['user_group_id'].to_i == 5 && p['club_id'].present? }&.dig('club_id')&.to_i
    end

    def apply_go_change(user, new_go_id)
      return { error: 'Kann eigene Zuweisung nicht ändern', status: :forbidden } if user.id == current_user.id

      return { error: 'Ungültiger Verbund', status: :unprocessable_entity } unless new_go_id.positive? && GameOperation.exists?(new_go_id)

      affected = user.permissions.select { |p| GO_SCOPED_ROLES.include?(p['user_group_id'].to_i) }
      if affected.empty?
        return { error: 'Benutzer hat keine SBK/RSK/Ansetzer-Rolle', status: :unprocessable_entity }
      end

      # Gegenstück zur Sperre für die vereinsgebundenen Rollen weiter oben in
      # apply_club_change: Der Zweig unten schreibt JEDE verbandsgebundene
      # Berechtigung auf die neue ID um. Hängen mehrere Verbände am Konto, wird
      # aus [{SBK, A}, {SBK, B}] dabei [{SBK, A}, {SBK, A}]; User#permission_hash
      # entdoppelt das per uniq, und der Zugriff auf Verband B ist weg. Der
      # Request antwortete mit 200, auffällig wurde es erst, wenn die Person
      # Ligen, Vereine oder Spieler des zweiten Verbands nicht mehr sah (#434).
      #
      # Die Benutzermaske kann den Fall gar nicht darstellen: Sie sucht mit
      # `find` die ERSTE verbandsgebundene Rolle und belegt damit ein einzelnes
      # Dropdown, der zweite Verband taucht nicht auf. Solange das so ist, ist
      # Abbrechen die einzige Antwort, die nichts verliert. remove_role plus
      # add_role behandeln mehrere Einträge bereits korrekt und bleiben der Weg.
      #
      # Gezählt werden die Verbände, nicht die Rollen: SBK und Ansetzer
      # desselben Verbands sind der Normalfall und ziehen gemeinsam um, ohne
      # dass etwas verloren geht.
      if affected.map { |p| p['game_operation_id'].to_s }.uniq.size > 1
        return { error: 'Benutzer ist mehreren Verbünden zugeordnet – Einzelzuweisung nicht möglich',
                 status: :unprocessable_entity }
      end

      # Der Wechsel muss in beide Richtungen im eigenen Zuständigkeitsbereich
      # liegen: Sonst schöbe ein verbandsgebundener SBK eine Rolle aus dem
      # eigenen Verband heraus oder eine fremde in ihn hinein. Admin und
      # national gescopte Konten sind über permission_assignable? unbeschränkt.
      unless affected.all? { |p| permission_assignable?(p) && permission_assignable?(p.merge('game_operation_id' => new_go_id.to_s)) }
        return { error: 'Verbund nicht im eigenen Zuständigkeitsbereich', status: :forbidden }
      end

      new_perms = user.permissions.map do |p|
        GO_SCOPED_ROLES.include?(p['user_group_id'].to_i) ? p.merge('game_operation_id' => new_go_id.to_s) : p
      end

      { updates: { permissions: new_perms } }
    end

    def derive_club_ids_for_go(go_ids)
      Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
    end

    # Zulässige Team-Zuweisung für ein TM-Konto auflösen. Rückgabeform wie bei
    # den apply_*_change-Geschwistern: { team_ids: } oder { error:, status: }.
    #
    # Nicht zuweisbare IDs werden bewusst nicht still gefiltert: Eine verworfene
    # Zuweisung erzeugt ein Konto, das sich nicht einloggen kann, und niemand
    # erfährt davon. Das gilt auch für unbrauchbare Eingaben (nicht-numerisch,
    # 0, nil): Sie dürfen nicht zu einer leeren Auswahl kollabieren, weil das
    # eine vorhandene Zuweisung löschen würde.
    #
    # Zuweisbar sind nur Teams der aktuellen Saison. Vorsaison-Teams zählen in
    # User#permission_hash nicht und sperren das Konto ebenso aus.
    def resolve_team_ids(raw_ids, ph, target_club_id: nil)
      # Hash-Form (teams[0]=5) landet als ActionController::Parameters hier und
      # kennt weder to_ary noch to_i. Ohne diese Prüfung ein 500 statt 422.
      return { error: 'teams muss eine Liste von Team-IDs sein', status: :unprocessable_entity } unless
        raw_ids.nil? || raw_ids.is_a?(Array)

      raw = Array(raw_ids)
      malformed = raw.reject { |v| v.to_s.match?(/\A[1-9]\d*\z/) }
      ids = raw.map(&:to_i).select(&:positive?).uniq

      assignable = assignable_team_scope(ph, target_club_id).where(id: ids).pluck(:id)
      rejected = (ids - assignable) + malformed

      return { error: rejected_teams_message(rejected), status: :unprocessable_entity } if rejected.any?

      { team_ids: assignable }
    end

    # Vereins-Scope der Team-Zuweisung. Dieselbe Quelle wie beim Zuweisen eines
    # Vereins (Club.role_assignable_for, siehe #create). Sonst dürfte ein
    # verbandsgebundener SBK über teams ein Team anhängen, dessen Verein ihm
    # über club_id verwehrt wird.
    def assignable_team_scope(ph, target_club_id)
      scope = Team.current_season
      # Team und Konto müssen zum selben Verein gehören, sonst driften club_id
      # und teams auseinander (und apply_club_change entscheidet später anhand
      # einer club_id, die zur Zuweisung nie gepasst hat).
      scope = owned_by_clubs(scope, [target_club_id]) if target_club_id.present?
      return scope if ph[:admin].present? || ph[:sbk]&.include?(0)

      allowed_club_ids = Club.role_assignable_for(current_user, include_deactivated: true).pluck(:id)
      owned_by_clubs(scope, allowed_club_ids)
    end

    # Stamm-Verein ODER SG-Partnerverein. Gleiche Semantik wie Team.by_club_id,
    # aber für eine Liste von Vereins-IDs (Überlappungs-Operator statt ANY),
    # analog ClubsController#current_teams_by_club. Diese Deckung ist nötig, weil
    # genau jener Endpunkt die Checkboxen der Maske füllt und dort die SG-Teams
    # der Partnervereine mit angeboten werden: Ohne sie lehnte die API einen
    # Haken ab, den sie selbst angeboten hat.
    def owned_by_clubs(scope, club_ids)
      ids = Array(club_ids).compact
      return scope.none if ids.empty?

      scope.where('teams.club_id IN (:ids) OR teams.syndicate_clubs && ARRAY[:ids]::integer[]', ids: ids)
    end

    # Setzt user.teams aus params[:teams], sofern ein TM-Konto angelegt wird und
    # der Parameter überhaupt mitkam. Liefert nil bei Erfolg, sonst
    # { error:, status: }. Für andere Rollen wird teams bewusst ignoriert, Teams
    # hängen nur an TM-Konten.
    def team_assignment_error(user, role_id, ph, target_club_id)
      return nil unless role_id == 5 && params.key?(:teams)

      result = resolve_team_ids(params[:teams], ph, target_club_id: target_club_id)
      return result if result[:error]

      user.teams = result[:team_ids]
      nil
    end

    def rejected_teams_message(rejected_ids)
      'Teams nicht zuweisbar (unbekannt, nicht in der aktuellen Saison, anderer ' \
        "Verein oder außerhalb des Zuständigkeitsbereichs): #{rejected_ids.join(', ')}"
    end

    def role_name(user_group_id)
      { 1 => 'Admin', 2 => 'SBK', 3 => 'RSK', 4 => 'VM', 5 => 'TM', 6 => 'Schiedsrichter', 7 => 'Ansetzer' }[user_group_id] || 'Unbekannt'
    end

    def user_json(user, full: false, lookups: nil)
      result = {
        id: user.id,
        username: user.user_name,
        name: user.fullname,
        first_name: user.first_name,
        last_name: user.last_name,
        email: user.email,
        club_id: user.club_id,
        archived_at: user.archived_at,
        inactive: user.last_login_at.present? ? user.last_login_at < 3.years.ago : user.created_at < 3.years.ago,
        last_login_at: user.last_login_at,
        created_at: user.created_at,
        updated_at: user.updated_at,
        roles: user.permissions.map do |p|
          club_id = p['club_id'].presence&.to_i
          go_id   = p['game_operation_id'].presence&.to_i
          {
            user_group_id: p['user_group_id'].to_i,
            role_name: role_name(p['user_group_id'].to_i),
            club_id: club_id,
            club_name: lookup_club_name(club_id, lookups),
            game_operation_id: go_id,
            game_operation_name: lookup_go_name(go_id, lookups)
          }
        end,
        # Aufgelöste Team-Namen für die Zuordnungs-Anzeige (relevant für TM).
        team_names: lookup_team_names(user.teams, lookups),
        # Konto ist von der TM-Sperre betroffen und kann sich nicht einloggen.
        # Ohne dieses Feld müsste die Liste die Sperre selbst herleiten, und
        # team_names taugt dafür nicht (nicht auf die Saison gefiltert).
        login_blocked: login_blocked?(user, lookups)
      }
      result[:teams] = user.teams if full
      result
    end

    # Spiegelt User#permissions_items (tm_blocked), rechnet aber gegen eine
    # vorab geladene Menge Saison-Teams statt über permission_hash: Das käme in
    # #index pro Konto auf eigene Queries. Der Test
    # 'login_blocked deckt sich mit permissions_items' hält beide Stellen
    # zusammen, damit die Doppelung nicht auseinanderläuft.
    def login_blocked?(user, lookups)
      role_ids = user.permissions.map { |p| p['user_group_id'].to_i }
      return false unless role_ids.include?(5)
      # Jede weitere Rolle hebt die Sperre auf (Schiri-Selfservice eingeschlossen).
      return false if role_ids.intersect?([1, 2, 3, 4, 6, 7])

      (Array(user.teams) & current_season_team_ids(lookups)).empty?
    end

    def current_season_team_ids(lookups)
      return lookups[:current_season_team_ids] if lookups

      Team.current_season.pluck(:id)
    end

    # Namens-Lookups für die Zuordnungs-Spalte vorab batchen (kein N+1 in #index).
    def assignment_lookups(users)
      club_ids = users.flat_map { |u| u.permissions.map { |p| p['club_id'].presence&.to_i } }.compact.uniq
      go_ids   = users.flat_map { |u| u.permissions.map { |p| p['game_operation_id'].presence&.to_i } }.compact.uniq
      team_ids = users.flat_map { |u| Array(u.teams) }.compact.uniq
      {
        clubs: Club.where(id: club_ids).pluck(:id, :name).to_h,
        game_operations: GameOperation.where(id: go_ids).pluck(:id, :name).to_h,
        teams: Team.where(id: team_ids).pluck(:id, :name).to_h,
        current_season_team_ids: Team.current_season.where(id: team_ids).pluck(:id)
      }
    end

    def lookup_club_name(club_id, lookups)
      return nil unless club_id

      lookups ? lookups[:clubs][club_id] : Club.find_by(id: club_id)&.name
    end

    def lookup_go_name(go_id, lookups)
      return nil unless go_id

      lookups ? lookups[:game_operations][go_id] : GameOperation.find_by(id: go_id)&.name
    end

    def lookup_team_names(team_ids, lookups)
      ids = Array(team_ids).compact
      return [] if ids.empty?

      if lookups
        ids.map { |tid| lookups[:teams][tid] }.compact
      else
        Team.where(id: ids).pluck(:name)
      end
    end
  end
end
