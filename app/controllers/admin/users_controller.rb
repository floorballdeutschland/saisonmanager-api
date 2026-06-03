module Admin
  class UsersController < ApplicationController
    before_action :authorize_user_management!
    before_action :set_managed_user, only: %i[show update destroy trigger_password_reset]
    before_action :require_admin_for_elevated_target!, only: %i[update trigger_password_reset]

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

      updates[:email] = params[:email] if params.key?(:email)

      if params.key?(:teams)
        if ph[:vm].present? && !ph[:admin].present? && !ph[:sbk].present?
          allowed_team_ids = Team.current_season.where(club_id: ph[:vm]).pluck(:id)
          updates[:teams] = Array(params[:teams]).map(&:to_i).select { |t| allowed_team_ids.include?(t) }
        else
          updates[:teams] = params[:teams]
        end
      end

      if params.key?(:active)
        unless ph[:admin].present? || ph[:sbk].present?
          return render json: { error: 'Nur SBK/Admin kann Benutzer deaktivieren' }, status: :forbidden
        end

        updates[:active] = params[:active]
      end

      if params.key?(:role)
        result = apply_role_change(@managed_user, params[:role].to_i, ph)
        return render json: { error: result[:error] }, status: result[:status] if result[:error]

        updates[:permissions] = result[:permissions]
      end

      if params.key?(:club_id)
        result = apply_club_change(@managed_user, params[:club_id].to_i, ph)
        return render json: { error: result[:error] }, status: result[:status] if result[:error]

        updates.merge!(result[:updates])
      end

      if params.key?(:game_operation_id)
        result = apply_go_change(@managed_user, params[:game_operation_id].to_i, ph)
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

      if ph[:vm].present? && !ph[:admin].present? && !ph[:sbk].present?
        return render json: { error: 'VM darf nur TM- oder VM-Nutzer anlegen' }, status: :forbidden unless [4, 5].include?(role_id)
        return render json: { error: 'Verein nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden unless club_id && ph[:vm].include?(club_id)

        perm = { 'user_group_id' => role_id }
        perm['club_id'] = club_id.to_s if role_id == 4
        user = User.new(user_create_params)
        user.password    = SecureRandom.hex(12)
        user.club_id     = club_id
        user.permissions = [perm]

        if params[:teams].is_a?(Array) && role_id == 5
          allowed_team_ids = Team.current_season.where(club_id: ph[:vm]).pluck(:id)
          user.teams = params[:teams].map(&:to_i).select { |t| allowed_team_ids.include?(t) }
        end

        if user.save
          user.send_reset_information
          return render json: user_json(user), status: :created
        else
          return render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end

      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end

      unless ph[:admin].present? || [4, 5].include?(role_id)
        return render json: { error: 'SBK darf nur VM- und TM-Nutzer anlegen' }, status: :forbidden
      end

      if [2, 3].include?(role_id) && !go_id
        return render json: { error: 'Verbund muss für SBK/RSK angegeben werden' }, status: :unprocessable_entity
      end

      if club_id && !ph[:admin].present?
        allowed = ph[:sbk].include?(0) ? Club.pluck(:id) : derive_club_ids_for_go(ph[:sbk])
        return render json: { error: 'Verein nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden unless allowed.include?(club_id)
      end

      perm = { 'user_group_id' => role_id }
      perm['club_id']           = club_id.to_s if club_id
      perm['game_operation_id'] = go_id.to_s   if go_id

      user = User.new(user_create_params)
      user.password    = SecureRandom.hex(12)
      user.club_id     = club_id if club_id
      user.permissions = [perm]

      if user.save
        user.send_reset_information
        render json: user_json(user), status: :created
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

    # POST /api/v2/admin/users/:id/trigger_password_reset
    def trigger_password_reset
      @managed_user.send_reset_information
      render json: { success: true }
    end

    private

    def scoped_users
      ph = current_user.permission_hash
      ids = if ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0)) ||
               (ph[:rsk].present? && ph[:rsk].include?(0))
              return User.all
            elsif ph[:sbk].present? || ph[:rsk].present?
              go_ids = (ph[:sbk] || []) + (ph[:rsk] || [])
              club_ids = derive_club_ids_for_go(go_ids)
              club_user_ids = User.where(club_id: club_ids).pluck(:id)
              lv_user_ids = lv_scoped_user_ids(go_ids)
              (club_user_ids + lv_user_ids).uniq
            elsif ph[:vm].present?
              User.where(club_id: ph[:vm]).pluck(:id)
            else
              []
            end
      User.where(id: (ids + [current_user.id]).uniq)
    end

    def lv_scoped_user_ids(go_ids)
      if go_ids.include?(0)
        User.where(
          "permissions @> '[{\"user_group_id\": 2}]' OR permissions @> '[{\"user_group_id\": 3}]'"
        ).pluck(:id)
      else
        conditions = go_ids.flat_map { |go_id|
          gid = go_id.to_i
          [
            "permissions @> '[{\"user_group_id\": 2, \"game_operation_id\": \"#{gid}\"}]'",
            "permissions @> '[{\"user_group_id\": 3, \"game_operation_id\": \"#{gid}\"}]'",
            "permissions @> '[{\"user_group_id\": 2, \"game_operation_id\": #{gid}}]'",
            "permissions @> '[{\"user_group_id\": 3, \"game_operation_id\": #{gid}}]'"
          ]
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
      return if current_user.permission_hash[:admin].present?

      target_roles = @managed_user.permissions.map { |p| p['user_group_id'].to_i }
      if (target_roles & [1, 2, 3]).any?
        render json: { error: 'Nicht berechtigt' }, status: :forbidden
      end
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

      updates[:teams] = [] if role_ids.include?(5)

      { updates: updates }
    end

    def apply_go_change(user, new_go_id, ph)
      return { error: 'Kann eigene Zuweisung nicht ändern', status: :forbidden } if user.id == current_user.id

      return { error: 'Ungültiger Verbund', status: :unprocessable_entity } unless new_go_id.positive? && GameOperation.exists?(new_go_id)

      unless ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))
        return { error: 'Nur Admin oder globaler SBK kann Verbund-Zuweisung ändern', status: :forbidden }
      end

      role_ids = user.permissions.map { |p| p['user_group_id'].to_i }
      unless role_ids.any? { |id| [2, 3].include?(id) }
        return { error: 'Benutzer hat keine SBK/RSK-Rolle', status: :unprocessable_entity }
      end

      new_perms = user.permissions.map do |p|
        [2, 3].include?(p['user_group_id'].to_i) ? p.merge('game_operation_id' => new_go_id.to_s) : p
      end

      { updates: { permissions: new_perms } }
    end

    def derive_club_ids_for_go(go_ids)
      Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
    end

    def role_name(user_group_id)
      { 1 => 'Admin', 2 => 'SBK', 3 => 'RSK', 4 => 'VM', 5 => 'TM', 6 => 'Schiedsrichter' }[user_group_id] || 'Unbekannt'
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
        active: user.active,
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
        team_names: lookup_team_names(user.teams, lookups)
      }
      result[:teams] = user.teams if full
      result
    end

    # Namens-Lookups für die Zuordnungs-Spalte vorab batchen (kein N+1 in #index).
    def assignment_lookups(users)
      club_ids = users.flat_map { |u| u.permissions.map { |p| p['club_id'].presence&.to_i } }.compact.uniq
      go_ids   = users.flat_map { |u| u.permissions.map { |p| p['game_operation_id'].presence&.to_i } }.compact.uniq
      team_ids = users.flat_map { |u| Array(u.teams) }.compact.uniq
      {
        clubs: Club.where(id: club_ids).pluck(:id, :name).to_h,
        game_operations: GameOperation.where(id: go_ids).pluck(:id, :name).to_h,
        teams: Team.where(id: team_ids).pluck(:id, :name).to_h
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
