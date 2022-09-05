class User < ApplicationRecord
  include UserTracker

  def login_hash
    {
      id:,
      email:,
      username: user_name,
      name: fullname,
      permissions: permissions_items
    }
  end

  def fullname
    [first_name, last_name].join ' '
  end

  def permissions_items
    result = {}
    ph = permission_hash

    result[:login_blocked] = !(ph[:admin].present? || ph[:sbk].present?)

    # show league admin menu item
    result[:menu_item_league_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_club_admin] = ph[:admin].present? || ph[:sbk].present?

    # show permissions
    result[:show_league_index_admin] = ph[:admin].present? || ph[:sbk].present?

    result
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
        tm_team_ids << Team.where(id: teams, league_id: all_league_ids)
      when 4 # Vereinsmanager
        vm_club_ids << perm['club_id'] if perm['club_id'].present?
      when 3 # RSK
        rsk_go_ids << go_id
      when 2 # 2 SBK
        sbk_go_ids << go_id
      when 1 # 1 Admin
        admin_go_ids << go_id
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

    hashed_password = Digest::MD5.hexdigest(password)
    user = User.where(user_name:).first

    user if user && user.old_password == hashed_password
  end
end
