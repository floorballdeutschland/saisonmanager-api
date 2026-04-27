class User < ApplicationRecord
  include UserTracker

  has_secure_password
  validates :user_name, presence: true, uniqueness: true

  belongs_to :referee, optional: true

  def login_hash
    perms = permissions_items
    {
      id:,
      email:,
      username: user_name,
      name: fullname,
      permissions: perms,
      club_ids:,
      referee_id: referee_id,
      login_blocked_message: perms[:login_blocked] ? 'Keine Teams in der aktuellen Saison.' : nil
    }
  end

  def fullname
    [first_name, last_name].join ' '
  end

  def full_with_username
    "#{fullname} (#{user_name})"
  end

  def send_reset_information
    self.password_reset_token = SecureRandom.uuid
    UserMailer.reset_password(self).deliver_now if save(validate: false)
  end

  def permissions_items
    result = {}
    ph = permission_hash

    has_tm_role = permissions.any? { |p| p['user_group_id'].to_i == 5 }
    has_schiri_role = permissions.any? { |p| p['user_group_id'].to_i == 6 }
    tm_blocked = has_tm_role && ph[:tm].blank? && ph[:admin].blank? && ph[:sbk].blank? && ph[:vm].blank?
    result[:login_blocked] = tm_blocked

    return result if tm_blocked

    if has_schiri_role && !ph[:admin].present? && !ph[:sbk].present? && !ph[:rsk].present? && !ph[:vm].present? && !ph[:tm].present?
      result[:menu_item_referee_profile] = true
      result[:show_page_referee_profile] = true
      return result
    end

    # show league admin menu item
    result[:menu_item_league_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_club_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_player_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_player_admin_vm] = ph[:vm].present?

    result[:menu_item_licence_list] =
      ph[:admin].present? || ph[:sbk].present? || ph[:vm].present? || ph[:tm].present?
    result[:menu_item_licence_club_admin] = ph[:vm].present? || ph[:tm].present?
    result[:menu_item_licence_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_referee_admin] = ph[:admin].present? || ph[:rsk].present?
    result[:menu_item_referee_assignments] = ph[:admin].present? || ph[:rsk].present?
    result[:menu_item_state_association_admin] = ph[:admin].present?
    result[:menu_item_api_key_admin] = ph[:admin].present?

    # show permissions
    result[:show_league_index_admin] = ph[:admin].present? || ph[:sbk].present?

    # update permissions
    result[:update_player] = ph[:admin].present? || ph[:sbk].present?
    result[:create_player] = true
    result[:player_transfer] = ph[:admin].present? || ph[:sbk].present?
    result[:player_add_additional_clubs] = ph[:admin].present? || ph[:sbk].present?
    result[:player_remove_additional_clubs] = ph[:admin].present? || ph[:sbk].present?

    result[:player_set_license_to_transfer] = ph[:admin].present? || special_user

    result
  end

  def club_ids
    permission_hash[:vm]
  end

  def special_user
    %w[jho_admin buettner_sbk mguenther].include?(user_name)
  end

  def permission_hash
    result = {}

    tm_team_ids = []
    vm_club_ids = []
    sbk_go_ids = []
    rsk_go_ids = []
    admin_go_ids = []

    all_league_ids = League.current_season.pluck(:id)

    permissions.each do |perm|
      go_id = perm['game_operation_id'].to_i

      case perm['user_group_id'].to_i
      when 5 # Teammanager
        tm_team_ids << Team.where(id: teams, league_id: all_league_ids).pluck(:id)
      when 4 # Vereinsmanager
        vm_club_ids << perm['club_id'].to_i if perm['club_id'].present?
      when 3 # RSK
        rsk_go_ids << go_id
      when 2 # SBK
        sbk_go_ids << go_id
      when 1 # Admin
        admin_go_ids << go_id
      when 6 # Schiedsrichter (self-service, no go_id needed)
        nil
      end
    end

    tm_team_ids.flatten!
    tm_team_ids.uniq!
    tm_team_ids.sort!
    rsk_go_ids.sort!.uniq!
    sbk_go_ids.sort!.uniq!
    admin_go_ids.sort!.uniq!

    all_go = [1, 2, 3, 4, 5, 6, 8, 9, 10, 11]

    result[:tm] = tm_team_ids if tm_team_ids.present?
    result[:vm] = vm_club_ids.uniq.sort if vm_club_ids.present?
    result[:rsk] = (all_go == rsk_go_ids ? [0] : rsk_go_ids) if rsk_go_ids.present?
    result[:sbk] = (all_go == sbk_go_ids ? [0] : sbk_go_ids) if sbk_go_ids.present?
    result[:admin] = (all_go == admin_go_ids ? [0] : admin_go_ids) if admin_go_ids.present?

    result
  end

  def self.login(user_name, password)
    return nil if user_name.blank? || password.blank?

    user = User.where(user_name:).first
    hashed_password = Digest::MD5.hexdigest(password)

    return nil if user.blank?

    # old md5 password
    if user.password_digest.blank? && user.old_password == hashed_password
      user.password = password
      user.password_confirmation = password
      user.password_reset_token = nil
      user.old_password = nil
      user.last_login_at = Time.now
      user if user.save
    elsif user.password_digest.present? && user.authenticate(password) && user.update(last_login_at: Time.now)
      user
    end
  end
end
