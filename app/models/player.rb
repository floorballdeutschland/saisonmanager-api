class Player < ApplicationRecord
  has_paper_trail

  belongs_to :created_at_user, class_name: 'User', optional: true
  belongs_to :updated_at_user, class_name: 'User', optional: true

  has_many :license_documents, dependent: :destroy
  has_many :suspensions, class_name: 'PlayerSuspension', dependent: :destroy

  validates :nation_id, presence: true
  validate :nation_id_is_positive, if: -> { nation_id.present? }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  # wo kommt das her?
  # attr_accessor :hash, :prefix

  scope :active, -> { where(deactivated_at: nil) }

  def meta_hash
    attributes.with_indifferent_access.slice(:id, :last_name, :first_name, :birthdate, :gender, :security_id, :deactivated_at)
  end

  def search_hash
    club_id = clubs&.first&.dig('club_id')
    {
      id:,
      last_name:,
      first_name:,
      birthdate:,
      gender:,
      club_id:
    }
  end

  def full_hash(with_licenses = false, only_current_licenses = false, license_with_titles = false)
    p = {
      id:,
      last_name:,
      first_name:,
      birthdate:,
      gender:,
      nation_id:,
      nation_string:,
      clubs:,
      security_id:,
      email:,
      deactivated_at:,
      deactivation_reason:
    }

    if with_licenses
      p[:licenses] = if only_current_licenses
                       (licenses || []).select { |l| l['team_id'].to_i >= Setting.current_min_team }
                     else
                       licenses
                     end

      if license_with_titles
        p[:licenses].map! do |lic|
          last_status_id = nil
          lic['history'].map! do |lh|
            lh[:created_by_name] = User.find_by(id: lh['created_by'])&.full_with_username
            lh[:license_status] = License::NAMES[lh['license_status_id'].to_i]
            last_status_id = lh['license_status_id'].to_i

            lh
          end

          lic[:set_transfer_allowed] = (last_status_id == License::APPROVED)

          team = Team.find_by(id: lic['team_id'])
          lic[:team] = team&.full_hash
          lic[:league] = team&.league&.full_hash

          lic
        end
      end
    end

    p
  end

  def some_hash(hash_type = :full, with_licenses = false, only_current_licenses = false)
    case hash_type
    when :full
      full_hash(with_licenses, only_current_licenses)
    when :short
      full_hash(with_licenses, only_current_licenses).select do |k, _v|
        %i[id first_name last_name birthdate].include? k
      end
    else
      {}
    end
  end

  def admin_players_clubs
    {
      club_id:
    }
  end

  def nation_string
    setting = Setting.first
    nations = setting['nations']

    nations[nation_id.to_s]['name']
  end

  def created_by_string
    created_at_user.user_name if created_at_user.present?
  end

  def updated_by_string
    updated_at_user.user_name if updated_at_user.present?
  end

  def main_license_hash(season_id, deadline = Date.today)
    # player clubs
    club_names = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.name : 'CLUB(FEHLER)'
    end

    club_ids = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.id : nil
    end.compact

    if current_licenses(season_id)
      sorted_licenses = current_licenses(season_id).map! do |x|
        x['sorting'] = League.class_rank(x['league_class_id'])
        x
      end
    end
    license = select_license sorted_licenses if sorted_licenses

    p = create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
    p.merge(other_license_count: (sorted_licenses || []).count - 1) if p
  end

  def secondary_license_hash(season_id, deadline = Date.today)
    # player clubs
    club_names = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.name : 'CLUB(FEHLER)'
    end

    club_ids = valid_clubs(deadline).map do |club_item|
      club = Club.find_by_id(club_item['club_id'])
      club ? club.id : nil
    end.compact

    if current_licenses(season_id)
      sorted_licenses = current_licenses(season_id).map! do |x|
        x['sorting'] = League.class_rank(x['league_class_id'])
        x
      end
    end
    licenses = other_licenses sorted_licenses if sorted_licenses

    if sorted_licenses
      licenses.map do |license|
        create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
      end
    end
  end

  def create_license_hash(license, sorted_licenses, club_names, club_ids, deadline)
    p = HashWithIndifferentAccess.new({
                                        id:,
                                        last_name:,
                                        first_name:,
                                        birthdate:,
                                        gender:,
                                        license_hash: sorted_licenses,
                                        license: license.to_json.to_s,
                                        clubs: club_names.to_json,
                                        club_ids: club_ids.to_json
                                      })

    valid_home_club = home_club(deadline)
    if valid_home_club
      p.merge!(home_club_id: valid_home_club.id,
               home_club: valid_home_club.name,
               home_club_operation: valid_home_club.home_game_operation&.name,
               home_club_state: valid_home_club.state)
    end

    if license
      p.merge!(team_id: license['team_id'],
               license_id: license['id'],
               league_class_id: license['league_class_id'],
               history: license['history'],
               league_class: Setting.league_class(license['league_class_id']),
               league_category_id: license['league_category_id'],
               league_category: (license['league_category_id'].present? ? Setting.league_category(license['league_category_id']) : 'x'))
    end

    team = Team.find_by_id license['team_id'] if license
    team_clubs = team.all_clubs if team
    if team_clubs.present?
      p.merge!(license_clubs: team_clubs.to_json, license_club: '', league_id: team.league_id)

      if team_clubs.map(&:id).include? p[:license_hash_id]
        p[:license_club] = p[:home_club]
        p[:license_club_state] = p[:home_club_state]
      elsif (team_clubs.map(&:id) & club_ids).size > 0
        # check which club should be choosen
        club = Club.find_by_id (team_clubs.map(&:id) & club_ids).first
        p[:license_club] = club ? club.name : 'FEHLER (LC)'
        p[:license_club_state] = club ? club.state : 'FEHLER (LCS)'
      else
        # check which club should be choosen
        club = Club.find_by_id team_clubs.first.id
        p[:license_club] = club ? club.name : 'FEHLER (LCA)'
        p[:license_club_state] = club ? club.state : 'FEHLER (LCSA)'
      end
    end

    p
  end

  def valid_clubs(deadline)
    clubs.reject { |l| valid_time?(l['valid_until'], deadline) } if clubs
  end

  def home_club(deadline)
    Club.find_by_id home_club_hash(deadline).last['club_id']
  end

  def home_club_hash(deadline)
    valid_clubs(deadline).reject { |l| !l['home_club'] || valid_time?(l['valid_until'], deadline) } if clubs
  end

  def current_licenses(sid = Setting.current_season_id)
    current_licenses_meta(Team.teams_by_season(sid))
  end

  def current_licenses_meta(teams)
    if licenses
      result = licenses.reject do |l|
        !teams.map(&:id).map(&:to_s).include?(l['team_id'].to_s)
      end
    end
    if result
      result.map do |x|
        x['sorting'] = League.class_rank(x['league_class_id'])
        x
      end
    end
  end

  def licenses_by_team(team_id)
    if licenses
      licenses.each do |l|
        return l if team_id.to_i == l['team_id'].to_i
      end
    end

    nil
  end

  def current_license_status(license)
    status = license['history'].sort_by { |h| h['created_at'] }.last

    status[:created_by_name] = User.find(status['created_by'])&.full_with_username
    status[:license_status] = License::NAMES[status['license_status_id'].to_i]

    status
  end

  def license_status_by_team(team_id)
    l = licenses_by_team(team_id)

    current_license_status(l) if l.present?
  end

  def transfer(new_club_id, user_id)
    # get clubs
    player_clubs = clubs
    # find old club
    old_club = nil
    player_clubs.each do |c|
      old_club = c['club_id'] if c['home_club'] == true && c['valid_until'].nil?
    end

    player_clubs.map! do |c|
      # only valid entries
      if c['valid_until'].nil? || c['valid_until'] > Time.now
        if c['home_club'] == true
          # set all home clubs unvalid
          c['valid_until'] = Time.now
          c['valid_set_by'] = user_id
        else
          # set all non home clubs unvalid
          c['valid_until'] = Time.now
          c['valid_set_by'] = user_id
        end
      end

      c
    end

    # set new home club
    player_clubs << {
      'club_id' => new_club_id,
      'home_club' => true,
      'created_at' => Time.now,
      'created_by' => user_id
    }

    updated_by_user = User.find user_id

    Transfer.create({
                      created_by: user_id,
                      former_club_id: old_club,
                      new_club_id:,
                      player_id: id,
                      season_id: Setting.current_season_id
                    })

    save!(validate: false)
  end

  def merge_into!(master, user_id)
    raise ArgumentError, 'Master und Secondary dürfen nicht identisch sein' if id == master.id
    raise ArgumentError, 'Secondary ist bereits zusammengeführt' if merged_into_id.present?
    raise ArgumentError, 'Master ist bereits zusammengeführt' if master.merged_into_id.present?

    ActiveRecord::Base.transaction do
      %w[first_name last_name birthdate gender nation_id security_id email].each do |field|
        master[field] = self[field] if master[field].blank? && self[field].present?
      end

      existing_club_ids = master.clubs.map { |c| c['club_id'] }
      clubs.each do |club|
        master.clubs << club unless existing_club_ids.include?(club['club_id'])
      end

      existing_team_ids = master.licenses.map { |l| l['team_id'] }
      licenses.each do |license|
        master.licenses << license unless existing_team_ids.include?(license['team_id'])
      end

      master.save!(validate: false)

      _rewrite_player_game_references(master.id)

      self.merged_into_id = master.id
      deactivate!(user_id, reason: 'Zusammenführung')

      MergeLog.record!(
        object_type: 'player',
        master_id: master.id, master_label: "#{master.last_name}, #{master.first_name}",
        merged_id: id, merged_label: "#{last_name}, #{first_name}",
        user_id: user_id
      )
    end
  end

  # Einheitlicher Helper für License-History-Mutationen.
  # Garantiert, dass season_id, created_by und created_at immer vorhanden sind,
  # um History-Inkonsistenzen (Bonner-Vorfall-Klasse) zu vermeiden.
  def append_license_history(license, status:, user_id:, reason: nil)
    license['history'] ||= []
    license['history'] << {
      'license_status_id' => status,
      'created_at' => Time.current.iso8601,
      'created_by' => user_id,
      'reason' => reason
    }.compact
  end

  # --- Erst-/Zweitlizenz im Großfeld-Erwachsenenbereich ----------------------
  #
  # Die Zuordnung ist eine manuelle Entscheidung (Wahl des Spielers, dokumentiert
  # durch SBK/Admin) und wird pro Wettbewerb (GF Erwachsene, getrennt nach
  # männlich/weiblich = League#female) im Lizenz-Eintrag gespeichert:
  #   gf_role:         'erstlizenz' | 'zweitlizenz' | nicht gesetzt
  #   gf_role_history: [{ gf_role, source, created_by, created_at }]
  # source: 'assign' = Erstzuordnung, 'swap' = Tausch (max. 1x/Saison),
  #         'auto' = automatische Gegenbuchung der Partner-Lizenz.

  GF_ROLES = %w[erstlizenz zweitlizenz].freeze
  GF_ROLE_SWAP_LIMIT = 1

  # Aktive Lizenz-Einträge desselben GF-Erwachsenen-Wettbewerbs (gleiche Saison,
  # gleiches female-Flag) – ohne den übergebenen Eintrag selbst.
  def gf_competition_licenses(license, league)
    (licenses || []).select do |l|
      next false if l['id'] == license['id']
      next false unless l['season_id'].to_s == license['season_id'].to_s

      last_status = l['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
      next false unless License::ACTIVE_STATUSES.include?(last_status)

      other_league = Team.find_by(id: l['team_id'])&.league
      other_league.present? && other_league.gf_adult? && other_league.female == league.female
    end
  end

  # Anzahl bereits erfolgter Tausch-Operationen in diesem Wettbewerb. Jeder
  # Tausch schreibt genau einen 'swap'-Eintrag auf die gewechselte Lizenz
  # (die Partner-Lizenz wird mit 'auto' gegengebucht); die Summe über alle
  # Wettbewerbs-Lizenzen zählt daher die Tausch-Vorgänge unabhängig davon,
  # von welcher Lizenz aus getauscht wurde.
  def gf_role_swap_count(license, league)
    ([license] + gf_competition_licenses(license, league)).sum do |l|
      Array(l['gf_role_history']).count { |h| h['source'] == 'swap' }
    end
  end

  # Setzt die Zuordnung einer Lizenz und bucht die Partner-Lizenzen des
  # Wettbewerbs gegen (mutiert nur, speichert nicht):
  # - Wird eine Lizenz Erstlizenz, werden alle anderen zur Zweitlizenz.
  # - Wird eine Lizenz Zweitlizenz und die einzige Partner-Lizenz ist noch
  #   nicht markiert, wird diese zur Erstlizenz.
  # role = nil entfernt die Zuordnung ohne Gegenbuchung.
  def apply_gf_role(license, role, league, user_id, source:)
    assign_gf_role(license, role, user_id, source)
    return if role.blank?

    partners = gf_competition_licenses(license, league)
    if role == 'erstlizenz'
      partners.each do |l|
        assign_gf_role(l, 'zweitlizenz', user_id, 'auto') unless l['gf_role'] == 'zweitlizenz'
      end
    elsif partners.size == 1 && partners.first['gf_role'] != 'erstlizenz'
      assign_gf_role(partners.first, 'erstlizenz', user_id, 'auto')
    end
  end

  def assign_gf_role(license, role, user_id, source)
    if role.blank?
      license.delete('gf_role')
    else
      license['gf_role'] = role
    end
    (license['gf_role_history'] ||= []) << {
      'gf_role' => role,
      'source' => source,
      'created_by' => user_id,
      'created_at' => Time.current.iso8601
    }
  end

  def deactivate!(user_id, reason: nil)
    clubs.map! do |c|
      if c['valid_until'].nil? || c['valid_until'].to_time > Time.now
        c['valid_until'] = Time.now
        c['valid_set_by'] = user_id
      end
      c
    end

    licenses.each do |license|
      last_status = license['history']&.last&.dig('license_status_id').to_i
      next unless last_status.in?([License::APPROVED, License::REQUESTED])

      license['history'] << {
        'license_status_id' => License::DELETED,
        'reason' => reason || 'Deaktiviert',
        'created_by' => user_id,
        'created_at' => Time.now
      }
    end

    self.deactivated_at = Time.current
    self.deactivated_by = user_id
    self.deactivation_reason = reason
    save!(validate: false)
  end

  def reactivate!
    deactivated_user = deactivated_by

    clubs.map! do |c|
      if c['valid_until'].present? && c['valid_set_by'] == deactivated_user
        c.delete('valid_until')
        c.delete('valid_set_by')
      end
      c
    end

    deactivation_system_reasons = ['Vereinsaustritt', 'Deaktiviert', 'Karriereende', 'Temporäre Pause']

    licenses.each do |license|
      last = license['history']&.last
      next unless last &&
                  last['license_status_id'].to_i == License::DELETED &&
                  (deactivation_system_reasons.include?(last['reason']) || last['reason']&.start_with?('Sonstiges: ')) &&
                  last['created_by'] == deactivated_user

      license['history'].pop
    end

    self.deactivated_at = nil
    self.deactivated_by = nil
    save!(validate: false)
  end

  # Einheitlicher Einstieg für beide Sperr-Ebenen aus Issue #508.
  # team_id == nil  → Beantragungssperre (Ebene 2): blockiert neue Anträge und
  #                   setzt ALLE aktuell aktiven Lizenzen auf "gesperrt".
  # team_id gesetzt → Lizenzaussetzung (Ebene 1): setzt nur die Lizenz dieses Teams aus.
  def suspend!(valid_until:, user_id:, team_id: nil, valid_from: Date.current, reason: nil)
    suspension = nil

    ActiveRecord::Base.transaction do
      lock! if persisted?
      self.licenses ||= []
      affected = []

      licenses.each do |license|
        next if team_id.present? && license['team_id'].to_i != team_id.to_i

        # Altdaten-Lizenzen können `_id` statt `id` oder gar keine id haben — vor dem
        # Speichern stabilisieren, damit lift_suspension! exakt dieselbe Lizenz findet.
        license['id'] ||= license.delete('_id') || Digest::UUID.uuid_v4

        last_status_id = license['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
        next unless License::ACTIVE_STATUSES.include?(last_status_id)

        license['history'] << {
          'license_status_id' => License::SUSPENDED,
          'reason' => reason.presence || 'Spielersperre',
          'created_by' => user_id,
          'created_at' => Time.now
        }
        affected << { 'license_id' => license['id'], 'previous_status_id' => last_status_id }
      end

      suspension = suspensions.create!(
        team_id:,
        valid_from:,
        valid_until:,
        reason:,
        affected_licenses: affected,
        created_by: user_id
      )

      save!(validate: false)
    end

    suspension
  end

  # Hebt eine Sperre auf: reaktiviert die betroffenen Lizenzen auf ihren vorherigen Status.
  def lift_suspension!(suspension, user_id:, reason: 'Sperre aufgehoben')
    return if suspension.lifted_at.present?

    ActiveRecord::Base.transaction do
      lock! if persisted?
      self.licenses ||= []

      Array(suspension.affected_licenses).each do |entry|
        next if entry['license_id'].blank?

        license = licenses.find { |l| l['id'] == entry['license_id'] }
        next unless license

        last_status_id = license['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
        # Nur reaktivieren, wenn die Lizenz seit der Sperre nicht manuell anders gesetzt wurde.
        next unless last_status_id == License::SUSPENDED

        license['history'] << {
          'license_status_id' => entry['previous_status_id'].to_i,
          'reason' => reason,
          'created_by' => user_id,
          'created_at' => Time.now
        }
      end

      suspension.update!(lifted_at: Time.current, lifted_by: user_id)
      save!(validate: false)
    end
  end

  # Lazy-Ablauf: hebt fällige Sperren dieses Spielers auf (auch ohne Cron korrekt).
  def expire_due_suspensions!(date: Date.current, user_id: nil)
    suspensions.due(date).each do |suspension|
      lift_suspension!(suspension, user_id: user_id || suspension.created_by, reason: 'Sperre abgelaufen')
    end
  end

  # Greift die Beantragungssperre (Ebene 2) zu einem bestimmten Datum?
  def application_blocked?(date: Date.current)
    expire_due_suspensions!(date:)
    suspensions.active.player_wide.covering(date).exists?
  end

  # Besteht eine aktive Lizenzaussetzung (Ebene 1) für ein konkretes Team?
  # Verhindert, dass eine gesperrte Team-Lizenz durch einen Neuantrag umgangen wird.
  def suspended_for_team?(team_id, date: Date.current)
    expire_due_suspensions!(date:)
    suspensions.active.where(team_id:).covering(date).exists?
  end

  def image
    return nil
    return if id % 10 > 4

    "https://robohash.org/#{id}-#{CGI.escape last_name.downcase}.png?size=400x400"
  end

  def image_small
    return nil
    return if id % 10 > 4

    "https://robohash.org/#{id}-#{CGI.escape last_name.downcase}.png?size=90x90"
  end

  def self.find_by_team_id(team_id)
    # alternative for array: extr_licenses->>'team_id' IN ('#{team_ids.join '\', \''

    # Player.find_by_sql(
    #   [
    #     "SELECT *, extr_license
    #     FROM
    #       (SELECT *, jsonb_array_elements(licenses) as extr_license
    #       FROM players) as subqry
    #     WHERE
    #       extr_license->>'team_id' = '?'
    #     ORDER BY last_name, first_name", id
    #   ]
    # )

    Player.find_by_sql [
      "select *, extr_license from (SELECT *, jsonb_array_elements(licenses) as extr_license FROM players ) as subqry WHERE extr_license->>'team_id' ='?' ORDER BY extr_license->>'team_id', last_name, first_name", team_id
    ]
  end

  # Batch-Variante von find_by_team_id: lädt die Spieler für mehrere Teams in
  # EINER Query statt einer pro Team (vermeidet die N+1 in League#licenses, die
  # über alle Teams einer Liga schleift – und in admin/licenses_controller pro
  # Liga erneut). Liefert ein Hash { team_id(int) => [Player, …] }; jeder Key
  # ist vorbelegt (leeres Array, falls kein Spieler). Pro (Spieler, Team) ein
  # Eintrag – Duplikate werden, anders als bei jsonb_array_elements, vermieden
  # (Aufrufer wie leagues_controller#preround_players riefen dafür bisher
  # .uniq(&:id) auf).
  def self.find_by_team_ids(team_ids)
    ids = Array(team_ids).map(&:to_i).uniq
    result = ids.index_with { [] }
    return result if ids.empty?

    players = Player.where(
      "EXISTS (SELECT 1 FROM jsonb_array_elements(licenses) AS l " \
      "WHERE (l->>'team_id')::int = ANY (ARRAY[?]::int[]))", ids
    ).order(:last_name, :first_name)

    id_set = ids.to_set
    players.each do |player|
      (player.licenses || []).map { |l| l['team_id'].to_i }.uniq.each do |t_id|
        result[t_id] << player if id_set.include?(t_id)
      end
    end
    result
  end

  def self.admin_user_players(user, club_id)
    club_object = Club.find(club_id)

    # wenn admin oder sbk global: füge alle hinzu
    ph = user.permission_hash
    club = if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
             club_object
           elsif ph[:admin].present? || ph[:sbk].present?
             go_ids = []
             go_ids << ph[:admin] if ph[:admin].present?
             go_ids << ph[:sbk] if ph[:sbk].present?

             # if club and permission share a go_id we are allowed to see this
             club_object if go_ids.flatten.intersection(club_object.game_operations_hash.map do |go|
                                                          go['game_operation_id']
                                                        end).present?
           elsif ph[:vm].present?
             club_object if ph[:vm].include?(club_id)
           end

    return unless club

    result = club.full_hash
    result[:players] = club.players.map(&:meta_hash)

    # this was the all club index code:
    # clubs = []

    # GameOperation.find(go_ids).each do |go|
    #   clubs << go.clubs
    # end

    # clubs << Club.find(ph[:vm]) if ph[:vm]&.present?

    # clubs = clubs.flatten.uniq

    # clubs.each do |c|
    #   item = c.full_hash
    #   item[:players] = c.players
    #   result << item
    # end

    result
  end

  def fix_player_licenses!
    team_ids = []
    licenses.reject! do |l|
      doublication = team_ids.include?(l['team_id'])
      team_ids << l['team_id']

      # filter licenses from current season
      doublication && Setting.current_min_team <= l['team_id']
    end

    save!
  end

  def delete_license!(team_id)
    licenses.reject! do |l|
      l['team_id'] == team_id
    end

    save!
  end

  private

  def valid_time?(time, deadline)
    !time.nil? && Date.parse(time) < deadline
  end

  def select_license(licenses)
    licenses.map! do |license|
      last_status = license['history'].last
      license.merge last_status
    end

    # Höchste Liga (kleinstes 'sorting') = Hauptlizenz (Anzeige-Konzept, nicht
    # die manuelle Erst-/Zweitlizenz-Zuordnung gf_role); bei gleicher Ligastufe
    # die zeitlich früher genehmigte Lizenz.
    sorted = licenses.sort_by { |x| [x['sorting'], License.approval_time(x)] }
    sorted.first
  end

  def other_licenses(licenses)
    selected = select_license(licenses)

    licenses.reject { |l| l['id'] == selected['id'] }
  end

  private

  def nation_id_is_positive
    errors.add(:nation_id, 'muss größer als 0 sein') unless nation_id.to_i > 0
  end

  def _rewrite_player_game_references(master_id)
    secondary_id = id

    Game.where("players->'home' @> ?", [{ player_id: secondary_id }].to_json)
        .or(Game.where("players->'guest' @> ?", [{ player_id: secondary_id }].to_json))
        .find_each do |game|
      %w[home guest].each do |side|
        game.players[side]&.each { |p| p['player_id'] = master_id if p['player_id'] == secondary_id }
      end
      if game.starting_players.present?
        game.starting_players.each_value do |positions|
          positions.transform_values! { |pid| pid == secondary_id ? master_id : pid }
        end
      end
      game.save!(validate: false)
    end
  end
end
