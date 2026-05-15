module Admin
  class UsersController < ApplicationController
    before_action :authorize_user_management!
    before_action :set_managed_user, only: %i[show update trigger_password_reset]
    before_action :require_admin_for_elevated_target!, only: %i[update trigger_password_reset]

    # GET /api/v2/admin/users
    def index
      render json: scoped_users.order(:last_name, :first_name, :user_name).map { |u| user_json(u) }
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
        return render json: { error: 'VM darf nur TM-Nutzer anlegen' }, status: :forbidden unless role_id == 5
        return render json: { error: 'Verein nicht im eigenen Zuständigkeitsbereich' }, status: :forbidden unless club_id && ph[:vm].include?(club_id)

        perm = { 'user_group_id' => 5 }
        user = User.new(user_create_params)
        user.password    = SecureRandom.hex(12)
        user.club_id     = club_id
        user.permissions = [perm]

        if params[:teams].is_a?(Array)
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

    # POST /api/v2/admin/users/:id/trigger_password_reset
    def trigger_password_reset
      @managed_user.send_reset_information
      render json: { success: true }
    end

    private

    def scoped_users
      ph = current_user.permission_hash
      if ph[:admin].present? || (ph[:sbk].present? && ph[:sbk].include?(0))
        User.all
      elsif ph[:sbk].present?
        club_ids = derive_club_ids_for_go(ph[:sbk])
        club_user_ids = User.where(club_id: club_ids).pluck(:id)
        lv_user_ids = lv_scoped_user_ids(ph[:sbk])
        User.where(id: (club_user_ids + lv_user_ids).uniq)
      elsif ph[:vm].present?
        User.where(club_id: ph[:vm])
      else
        User.none
      end
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
            "permissions @> '[{\"user_group_id\": 3, \"game_operation_id\": \"#{gid}\"}]'"
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
      return if ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?

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

    def derive_club_ids_for_go(go_ids)
      Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
    end

    def role_name(user_group_id)
      { 1 => 'Admin', 2 => 'SBK', 3 => 'RSK', 4 => 'VM', 5 => 'TM', 6 => 'Schiedsrichter' }[user_group_id] || 'Unbekannt'
    end

    def user_json(user, full: false)
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
          {
            user_group_id: p['user_group_id'].to_i,
            role_name: role_name(p['user_group_id'].to_i),
            club_id: p['club_id']&.to_i,
            game_operation_id: p['game_operation_id']&.to_i
          }
        end
      }
      result[:teams] = user.teams if full
      result
    end
  end
end
