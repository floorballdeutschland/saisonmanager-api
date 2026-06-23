class User < ApplicationRecord
  include UserTracker

  LANGUAGES = %w[de en].freeze

  has_secure_password
  validates :user_name, presence: true, uniqueness: true
  validates :language, inclusion: { in: LANGUAGES }

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
      language:,
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

  # Wie send_reset_information, aber mit Begrüßungs-Mail (Benutzername + Link zum
  # erstmaligen Passwort-Setzen) für ein frisch angelegtes Schiedsrichter-Konto.
  def send_referee_account_information
    self.password_reset_token = SecureRandom.uuid
    UserMailer.referee_account_created(self).deliver_now if save(validate: false)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def permissions_items
    result = {}
    ph = permission_hash

    has_tm_role = permissions.any? { |p| p['user_group_id'].to_i == 5 }
    has_schiri_role = permissions.any? { |p| p['user_group_id'].to_i == 6 }
    tm_blocked = has_tm_role && ph[:tm].blank? && ph[:admin].blank? && ph[:sbk].blank? && ph[:vm].blank?
    result[:login_blocked] = tm_blocked

    return result if tm_blocked

    if has_schiri_role && !ph[:admin].present? && !ph[:sbk].present? && !ph[:rsk].present? && !ph[:ansetzer].present? && !ph[:vm].present? && !ph[:tm].present?
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
    has_full_referee_access = ph[:admin].present? || (ph[:rsk].present? && ph[:rsk].include?(0))
    # Ansetzer brauchen Lesezugriff auf die Schiedsrichterdaten (für die Ansetzung),
    # bekommen aber – wie LV-RSK – nur eingeschränkten Zugriff (kein Anlegen/Volledit).
    result[:menu_item_referee_admin] = ph[:admin].present? || ph[:rsk].present? || ph[:sbk].present? || ph[:ansetzer].present?
    result[:referee_edit_restricted] = !has_full_referee_access if result[:menu_item_referee_admin]
    result[:referee_can_create] = ph[:admin].present? || ph[:rsk].present? if result[:menu_item_referee_admin]
    result[:referee_can_delete_user] = ph[:admin].present? if result[:menu_item_referee_admin]
    result[:referee_wallet] = has_full_referee_access if result[:menu_item_referee_admin]
    # Ansetzungen macht die Ansetzer-Rolle (in manchen LV von der RSK getrennt).
    result[:menu_item_referee_assignments] = ph[:admin].present? || ph[:ansetzer].present?
    # Wochenend-Verfügbarkeitsübersicht der Schiris („war room") – für die Ansetzung.
    result[:menu_item_referee_availability] = ph[:admin].present? || ph[:ansetzer].present?
    # Strafcode-Verwaltung („Einstellungen" im Schiedsrichterwesen) – nur Admin.
    result[:menu_item_referee_settings] = ph[:admin].present?
    # Schiri-Feedback der Vereine ist nur am Schiri-Profil sichtbar – für Admin
    # sowie die global gescopten FD-Rollen (RSK/Ansetzer mit Spielbetrieb 0).
    result[:referee_feedback_view] =
      ph[:admin].present? ||
      (ph[:rsk].present? && ph[:rsk].include?(0)) ||
      (ph[:ansetzer].present? && ph[:ansetzer].include?(0))
    result[:menu_item_referee_course_import] = has_full_referee_access
    result[:menu_item_referee_course_review] = has_full_referee_access || lv_rsk_review_enabled?(ph)
    result[:menu_item_online_test_admin] = ph[:admin].present? || ph[:rsk].present?
    result[:menu_item_referee_vm] = ph[:vm].present?
    result[:menu_item_player_vm] = ph[:vm].present? || ph[:tm].present?
    # Portal „Meine Spieltage" für Gastmannschafts-Bestätigung (TM/VM).
    result[:menu_item_team_game_days] = ph[:tm].present? || ph[:vm].present?
    # Portal „Schiri-Feedback" – verpflichtende Rückmeldung der Vereine nach dem
    # Spiel. Nur sichtbar, wenn der/die Nutzer:in tatsächlich eine Mannschaft in
    # einer feedback-pflichtigen Liga (referee_feedback_enabled, z. B. 1. BL)
    # verantwortet – als TM (eigene Teams) oder VM (Teams des eigenen Vereins).
    result[:menu_item_referee_feedback] = manages_referee_feedback_team?(ph)
    # Globaler Admin und global gescopter SBK (z. B. FD-SBK, ph[:sbk] enthält 0)
    # bekommen den vollen Verbandsverwaltungs-View über alle Landesverbände.
    global_sbk = ph[:sbk].present? && ph[:sbk].include?(0)
    result[:menu_item_state_association_admin] = ph[:admin].present? || global_sbk
    result[:menu_item_state_association_sbk] = sbk_state_association_menu_item?(ph)
    # Anlegen/Löschen ganzer Landesverbände sowie das Umhängen des übergeordneten
    # Verbands bleiben globalen Admins vorbehalten (Backend: authorize_admin! /
    # parent_id-Strip). Der globale SBK verwaltet alle LVs, aber nicht deren Lebenszyklus.
    result[:state_association_manage_lifecycle] = ph[:admin].present?
    result[:menu_item_api_key_admin] = ph[:admin].present?
    result[:menu_item_transfer_requests] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
    result[:menu_item_transfer_requests_sbk] = ph[:admin].present? || ph[:sbk].present?
    # SBK-Menüpunkt „Verfahrensvorschläge" (manueller VSK-Workflow).
    result[:menu_item_proceeding_proposal_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_player_change_requests] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
    result[:create_player_change_request] = ph[:vm].present? || ph[:admin].present?
    result[:approve_player_change_request] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_user_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:user_delete] = ph[:admin].present?
    # Mehrfachrollen (Rollen je Konto hinzufügen/entfernen, z. B. RSK + Ansetzer) – nur Admin.
    result[:manage_user_roles] = ph[:admin].present?
    # VM dürfen TM-/VM-Konten im Scope ihres Vereins anlegen (Backend:
    # UsersController#create + authorize_user_management!).
    result[:menu_item_user_create] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present?
    result[:menu_item_user_vm] = ph[:vm].present?
    result[:menu_item_arena_admin] = ph[:admin].present? || ph[:sbk].present?
    result[:menu_item_season_admin] = ph[:admin].present?
    result[:menu_item_analytics_admin] = ph[:admin].present?
    result[:menu_item_email_log_admin] = ph[:admin].present?
    result[:menu_item_email_template_admin] = ph[:admin].present?

    # show permissions
    result[:show_league_index_admin] = ph[:admin].present? || ph[:sbk].present?

    # update permissions
    result[:update_player] = ph[:admin].present? || ph[:sbk].present?
    result[:create_player] = true
    result[:player_transfer] = ph[:admin].present? || ph[:sbk].present?
    result[:player_add_additional_clubs] = ph[:admin].present? || ph[:sbk].present?
    result[:player_remove_additional_clubs] = ph[:admin].present? || ph[:sbk].present?

    result[:player_deactivate] = ph[:admin].present? || ph[:sbk].present? || ph[:vm].present? || ph[:tm].present?
    result[:update_player_email] = ph[:vm].present? || ph[:tm].present?
    result[:player_set_license_to_transfer] = ph[:admin].present? || special_user
    result[:player_merge] = ph[:admin].present? || ph[:sbk].present?
    result[:player_suspend] = ph[:admin].present? || ph[:sbk].present?
    result[:referee_merge] = ph[:admin].present? || ph[:rsk].present?

    result[:club_deactivate] = ph[:admin].present? || ph[:sbk].present?

    result
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def club_ids
    permission_hash[:vm]
  end

  def sbk_state_association_menu_item?(perm_hash)
    !perm_hash[:admin].present? &&
      perm_hash[:sbk].present? &&
      !perm_hash[:sbk]&.include?(0)
  end

  # LV-RSK sieht die Kursergebnis-Freigabe nur, wenn mindestens einer seiner
  # Landesverbände den Kontrollprozess aktiviert hat
  # (effective_referee_license_review_enabled). Admin/globaler FD-RSK sind über
  # has_full_referee_access bereits abgedeckt.
  def lv_rsk_review_enabled?(perm_hash)
    go_ids = perm_hash[:rsk].to_a.reject(&:zero?)
    return false if go_ids.empty?

    sa_ids = GameOperation.where(id: go_ids).pluck(:state_association_id).compact.uniq
    StateAssociation.where(id: sa_ids).any?(&:effective_referee_license_review_enabled)
  end

  def special_user
    %w[jho_admin buettner_sbk mguenther].include?(user_name)
  end

  # True, wenn der/die Nutzer:in mindestens eine Mannschaft verantwortet, die in
  # einer feedback-pflichtigen Liga der aktuellen Saison aktiv ist (TM: eigene
  # Teams; VM: Teams des eigenen Vereins). Berücksichtigt auch Pokal-/Zusatzligen
  # eines Teams (Team#all_league_ids).
  def manages_referee_feedback_team?(perm_hash)
    return false unless perm_hash[:tm].present? || perm_hash[:vm].present?

    enabled_league_ids = League.current_season.where(referee_feedback_enabled: true).pluck(:id)
    return false if enabled_league_ids.empty?

    team_ids = Array(perm_hash[:tm])
    team_ids += Team.where(club_id: Array(perm_hash[:vm])).pluck(:id) if perm_hash[:vm].present?
    return false if team_ids.empty?

    Team.where(id: team_ids).any? { |team| (team.all_league_ids & enabled_league_ids).present? }
  end

  def permission_hash
    result = {}

    tm_team_ids = []
    vm_club_ids = []
    sbk_go_ids = []
    rsk_go_ids = []
    ans_go_ids = []
    admin_go_ids = []

    all_league_ids = League.current_season.pluck(:id)

    permissions.each do |perm|
      go_id = perm['game_operation_id'].to_i

      case perm['user_group_id'].to_i
      when 5 # Teammanager
        tm_team_ids << Team.where(id: teams, league_id: all_league_ids).pluck(:id)
      when 4 # Vereinsmanager
        vm_club_ids << perm['club_id'].to_i if perm['club_id'].present?
      when 7 # Ansetzer
        ans_go_ids << go_id
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
    ans_go_ids.sort!.uniq!
    sbk_go_ids.sort!.uniq!
    admin_go_ids.sort!.uniq!

    # SBK/RSK/Ansetzer for a national-level GO (no state_association_id, e.g. FD) gets global scope
    if sbk_go_ids.any? && !sbk_go_ids.include?(0) && GameOperation.where(id: sbk_go_ids, state_association_id: nil).exists?
      sbk_go_ids = [0]
    end
    if rsk_go_ids.any? && !rsk_go_ids.include?(0) && GameOperation.where(id: rsk_go_ids, state_association_id: nil).exists?
      rsk_go_ids = [0]
    end
    if ans_go_ids.any? && !ans_go_ids.include?(0) && GameOperation.where(id: ans_go_ids, state_association_id: nil).exists?
      ans_go_ids = [0]
    end

    all_go = [1, 2, 3, 4, 5, 6, 8, 9, 10, 11]

    result[:tm] = tm_team_ids if tm_team_ids.present?
    result[:vm] = vm_club_ids.uniq.sort if vm_club_ids.present?
    result[:rsk] = (all_go == rsk_go_ids ? [0] : rsk_go_ids) if rsk_go_ids.present?
    result[:ansetzer] = (all_go == ans_go_ids ? [0] : ans_go_ids) if ans_go_ids.present?
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
