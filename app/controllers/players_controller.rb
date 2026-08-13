class PlayersController < ApplicationController
  include LicenseDocumentPresentation
  include LicenseAccessScope

  before_action :set_player, only: %i[show update destroy]
  skip_before_action :authenticate_user, only: %i[transfers_public stats]
  before_action :authenticate_public_request, only: %i[transfers_public stats]

  # GET /players
  def index
    @players = Player.all.order(:last_name).order(:first_name).where("last_name != '' AND first_name != ''").order(:birthdate)
  end

  # GET /players/1
  def show; end

  def admin_players_index
    if current_user
      result = Player.admin_user_players(current_user, params[:club_id].to_i) || []

      render json: result
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def user_get_nations
    result = []

    Setting.current.nations.each do |k, v|
      item = {
        id: k,
        name: v['name'],
        eu: v['eu'],
        short_name: v['short_name']
      }

      result << item
    end

    render json: result
  end

  def global_search
    if current_user
      ph = current_user.permission_hash
      unless ph[:admin].present? || ph[:sbk].present?
        return render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

      q = params[:q].to_s.strip
      return render json: [] if q.length < 2

      term = "%#{q}%"
      players = Player.active.where(
        'last_name ILIKE :q OR first_name ILIKE :q OR concat(first_name, \' \', last_name) ILIKE :q OR concat(last_name, \', \', first_name) ILIKE :q',
        q: term
      ).order(:last_name, :first_name).limit(20)

      render json: players.map(&:search_hash)
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def admin_player
    if current_user
      result = Player.find(params[:id])
      unless can_manage_player?(result)
        return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
      end

      # Standardmäßig nur die aktuelle Saison; mit all_licenses=true die
      # vollständige, saisonübergreifende Lizenzhistorie (Spielerprofil).
      only_current = params[:all_licenses].to_s != 'true'
      render json: result.full_hash(true, only_current, true)
    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def request_license
    team = Team.find(params[:team_id])
    league = team.league

    # Ohne auflösbare Liga gibt es weder Altersgrenze noch Saison und
    # Ligaklasse für die Lizenz. league wird unten mehrfach ohne Schutz
    # dereferenziert; das ergab denselben 500er wie auf der Mannschaftsseite
    # (Sentry SAISONMANAGER-1C). Es gibt keinen Fremdschlüssel auf
    # teams.league_id, die Spalte ist zudem nullable.
    #
    # Vor der Rechteprüfung: Der Spielbetriebs-Scope der SBK-Rolle wird aus
    # genau dieser Liga abgeleitet. Stünde die Prüfung danach, bekäme die
    # zuständige SBK für ein Team ohne Liga eine Rechte-Absage statt dieser
    # zutreffenden Meldung.
    if league.nil?
      return render json: { message: 'Mannschaft ist keiner Liga zugeordnet.' }, status: :unprocessable_entity
    end

    ph = current_user.permission_hash
    allowed = may_manage_team?(ph, team)

    return render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden unless allowed

    guardian_email   = params[:guardian_email].is_a?(String) ? params[:guardian_email].presence : nil
    minor_consent_at = params[:minor_consent_at].is_a?(String) ? params[:minor_consent_at].presence : nil

    if guardian_email && !URI::MailTo::EMAIL_REGEXP.match?(guardian_email)
      return render json: { message: 'Ungültige E-Mail-Adresse der gesetzlichen Vertretung.' },
                    status: :unprocessable_entity
    end

    # Maßgeblich ist der LV des Spielbetriebs der Liga, nicht der des Vereins:
    # Zuständig für den Spielbetrieb einer Liga ist allein deren Verband. Erlaubnis
    # und Zeitfenster müssen aus derselben Liga stammen (League#express_license_possible?).
    #
    # Die konkrete Liga festhalten, nicht nur ein Ja/Nein: `team.leagues` umfasst
    # neben der Hauptliga auch Pokal-Ligen (Team#all_league_ids), deren Spielbetrieb
    # einem anderen Verband gehören kann. Der Antrag muss an die SBK genau des
    # Verbands gehen, der die Expresslizenz erlaubt – sonst erlaubt sie Verband A
    # und die Mail landet bei Verband B.
    express_league = nil
    if params[:express] == true || params[:express] == 'true'
      express_league = team.leagues.find(&:express_license_possible?)
    end
    express_requested = express_league.present?

    result = :ok
    player = nil

    ActiveRecord::Base.transaction do
      player = Player.lock.find(params[:id])
      player.licenses ||= []

      # Die player_id kommt aus der URL: ohne diese Prüfung kann ein TM jeden
      # beliebigen Spieler des Gesamtbestands in sein eigenes Team lizenzieren.
      # Admins bleiben ausgenommen, damit Korrekturen an Altdaten möglich sind.
      if ph[:admin].blank? && !player_in_team_clubs?(player, team)
        result = :not_in_club
        raise ActiveRecord::Rollback
      end

      if player.application_blocked?
        result = :blocked
        raise ActiveRecord::Rollback
      end

      if player.suspended_for_team?(team.id)
        result = :team_suspended
        raise ActiveRecord::Rollback
      end

      active_statuses = [License::APPROVED, License::REQUESTED, License::DELETE_REQUESTED].map(&:to_s).to_set
      if player.licenses.any? do |l|
           next false unless l['team_id'].to_i == team.id && l['season_id'].to_s == league.season_id.to_s

           last = l['history']&.max_by { |h| h['created_at'] }
           last && active_statuses.include?(last['license_status_id'].to_s)
         end
        result = :duplicate
        raise ActiveRecord::Rollback
      end

      unless league.age_eligible?(player.birthdate)
        result = :age_ineligible
        raise ActiveRecord::Rollback
      end

      new_license = {
        id: Digest::UUID.uuid_v4,
        team_id: team.id,
        season_id: league.season_id,
        league_class_id: league.league_class_id,
        express: express_requested,
        history: [{
          license_status_id: License::REQUESTED,
          created_by: current_user.id,
          created_at: Time.now
        }]
      }
      new_license[:guardian_email]   = guardian_email   if guardian_email
      new_license[:minor_consent_at] = minor_consent_at if minor_consent_at
      # Die Sperr-Checks oben können via Lazy-Ablauf ein reload auslösen — Liste erneut absichern.
      player.licenses ||= []
      player.licenses << new_license

      result = :save_failed unless player.save
    end

    case result
    when :not_in_club
      render json: { message: 'Der Spieler hat keine laufende Mitgliedschaft im Verein dieses Teams. ' \
                              'Eine Lizenz kann nur für Vereinsmitglieder beantragt werden.' },
             status: :unprocessable_entity
    when :blocked
      render json: { message: 'Für diesen Spieler besteht eine aktive Sperre. Es können keine Lizenzen beantragt werden.' },
             status: :unprocessable_entity
    when :team_suspended
      render json: { message: 'Die Lizenz dieses Spielers für dieses Team ist gesperrt. Ein neuer Antrag ist erst nach Ablauf der Sperre möglich.' },
             status: :unprocessable_entity
    when :duplicate
      render json: { message: 'Der Spieler hat schon einen Lizenzantrag für dieses Team' },
             status: :unprocessable_entity
    when :age_ineligible
      direction = league.before_deadline ? 'geboren bis' : 'geboren ab'
      render json: { message: "Der Spieler erfüllt die Altersvoraussetzung dieser Liga nicht (spielberechtigt: #{direction} #{league.deadline.strftime('%d.%m.%Y')})." },
             status: :unprocessable_entity
    when :save_failed
      render json: { message: player.errors }, status: :unprocessable_entity
    when :ok
      # express_league, nicht league: die Erlaubnis kann aus einer Pokal-Liga
      # stammen, deren Verband dann auch den Antrag erhält.
      PlayerMailer.express_license_requested(player, team, express_league).deliver_later if express_league
      render json: { success: true }
    else
      # Erfolg ist bewusst `when :ok`, nicht der else-Zweig: Ein künftig
      # ergänztes Abbruch-Symbol ohne eigenen Zweig würde sonst als Erfolg
      # gemeldet und löste sogar die Expresslizenz-Mail für eine Lizenz aus,
      # die die Transaktion gerade zurückgerollt hat.
      Sentry.capture_message("request_license: unbehandeltes Ergebnis #{result.inspect}") if defined?(Sentry)
      render json: { message: 'Der Lizenzantrag konnte nicht verarbeitet werden.' },
             status: :internal_server_error
    end
  end

  def handle_license_request
    player = Player.find(params[:id])
    ph = current_user.permission_hash

    license = player.licenses.find { |lic| lic['id'] == params[:license_id] }

    if (ph[:admin].present? || sbk_can_access_license?(ph, license)) && player.present?
      if params[:license_status_id].to_i == License::APPROVED && player.application_blocked?
        return render json: { message: 'Für diesen Spieler besteht eine aktive Sperre. Lizenzen können nicht erteilt werden.' },
                      status: :unprocessable_entity
      end

      # Optionale Erst-/Zweitlizenz-Zuordnung bei der Genehmigung (nur GF-Erwachsenenbereich).
      gf_role = params[:gf_role].presence
      if gf_role
        unless Player::GF_ROLES.include?(gf_role)
          return render json: { message: 'Ungültige Erst-/Zweitlizenz-Zuordnung.' }, status: :unprocessable_entity
        end

        gf_league = license && Team.find_by(id: license['team_id'])&.league
        unless gf_league&.gf_adult?
          return render json: { message: 'Eine Erst-/Zweitlizenz-Zuordnung gibt es nur im Großfeld-Erwachsenenbereich.' },
                        status: :unprocessable_entity
        end
      end

      approved_team_id = nil

      player.licenses.map! do |lic|
        if lic['id'] == params[:license_id]
          last_status = lic['history'].sort_by { |h| h['created_at'] }.last

          if last_status['license_status_id'].to_i != params[:license_status_id].to_i &&
             ([License::APPROVED, License::DENIED, License::REQUESTED].include?(params[:license_status_id].to_i) ||
              ([License::TRANSFER].include?(params[:license_status_id].to_i) && current_user.permission_hash[:admin].present?)
             )
            lic['history'] << {
              license_status_id: params[:license_status_id].to_i,
              reason: params[:reason] || '',
              created_by: current_user.id,
              created_at: Time.now
            }
            if params[:license_status_id].to_i == License::APPROVED
              approved_team_id = lic['team_id']
              lic['valid_until'] = params[:valid_until].presence || default_license_valid_until(lic['season_id']).iso8601
            end
          end
        end

        lic
      end

      # Zuordnung erst nach erfolgtem Statuswechsel setzen – inkl. automatischer
      # Gegenbuchung der bestehenden GF-Lizenz im selben Wettbewerb.
      if approved_team_id && gf_role
        approved_license = player.licenses.find { |l| l['id'] == params[:license_id] }
        player.apply_gf_role(approved_license, gf_role, gf_league, current_user.id, source: 'assign')
      end

      if player.save
        if approved_team_id && player.email.present?
          team = Team.find_by(id: approved_team_id)
          PlayerMailer.license_approved(player, team).deliver_later if team
        end
        render json: { success: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  # Setzt oder tauscht die Erst-/Zweitlizenz-Zuordnung einer Lizenz im
  # GF-Erwachsenenbereich (gf_role: 'erstlizenz' | 'zweitlizenz' | leer =
  # Zuordnung entfernen). Ein Tausch einer bestehenden Zuordnung ist pro Saison
  # und Wettbewerb nur einmal erlaubt – Admins dürfen das Limit überstimmen.
  def set_gf_license_role
    player = Player.find(params[:id])
    ph = current_user.permission_hash

    license = (player.licenses || []).find { |l| l['id'] == params[:license_id] }
    return render json: { message: 'Lizenz nicht gefunden.' }, status: :not_found unless license

    unless ph[:admin].present? || sbk_can_access_license?(ph, license)
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    role = params[:gf_role].presence
    if role && !Player::GF_ROLES.include?(role)
      return render json: { message: 'Ungültige Erst-/Zweitlizenz-Zuordnung.' }, status: :unprocessable_entity
    end

    league = Team.find_by(id: license['team_id'])&.league
    unless league&.gf_adult?
      return render json: { message: 'Eine Erst-/Zweitlizenz-Zuordnung gibt es nur im Großfeld-Erwachsenenbereich.' },
                    status: :unprocessable_entity
    end

    last_status = license['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
    unless License::ACTIVE_STATUSES.include?(last_status)
      return render json: { message: 'Nur aktive Lizenzen (erteilt oder beantragt) können zugeordnet werden.' },
                    status: :unprocessable_entity
    end

    if license['gf_role'].to_s == role.to_s
      return render json: { message: 'Die Zuordnung ist unverändert.' }, status: :unprocessable_entity
    end

    # Wechsel einer bestehenden Zuordnung = Tausch → Saisonlimit prüfen.
    is_swap = role.present? && license['gf_role'].present?
    if is_swap && ph[:admin].blank? && player.gf_role_swap_count(license, league) >= Player::GF_ROLE_SWAP_LIMIT
      return render json: { message: 'Die Erst-/Zweitlizenz-Zuordnung wurde in dieser Saison bereits getauscht. ' \
                                     'Ein weiterer Tausch ist nur durch die FD-Administration möglich.' },
                    status: :unprocessable_entity
    end

    player.apply_gf_role(license, role, league, current_user.id, source: is_swap ? 'swap' : 'assign')

    if player.save
      render json: { success: true }
    else
      render json: { message: player.errors }, status: :unprocessable_entity
    end
  end

  def handle_license_doublication
    if current_user && %w[jho_admin buettner_sbk mguenther].include?(current_user.user_name)
      player = Player.find(params[:id])
      player.fix_player_licenses!

      render json: { success: true }
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def admin_licenses
    league = League.find(params[:id])
    ph = current_user.permission_hash
    unless ph[:admin].present? || sbk_can_access_leagues?(ph, [league])
      return render json: { message: 'Keine Berechtigung!' }, status: :forbidden
    end

    result = league.licenses(true)

    all_player_ids = result.flat_map { |t| t[:players].map { |p| p[:id] } }.uniq
    if all_player_ids.present?
      # Dokumente gelten pro Spieler (saisonübergreifend); altersabhängige
      # Dokumentarten werden zum Datum der Lizenzbeantragung aufgelöst.
      docs_by_key = license_documents_by_player_and_type(all_player_ids)
      catalog = document_type_catalog((league.required_documents || []) + ['parental_consent'])
      result.each do |team_data|
        team_data[:players].each do |player_data|
          player_id = player_data[:id]
          required_keys = DocumentType.required_keys(
            league.required_documents,
            birthdate: player_data[:birthdate],
            requested_at: license_requested_at(player_data.dig(:team_license, :license)),
            catalog: catalog
          )
          player_data[:team_license][:required_documents] = required_keys
          player_data[:team_license][:documents] =
            document_map_for(player_id, league.season_id, docs_by_key, required_keys, catalog)
        end
      end
    end

    render json: result
  end

  def user_licenses_temp
    # hole spieler
    league = League.find(params[:id])

    ph = current_user.permission_hash

    # get playing clubs, including sg
    teams = league.teams
    club_ids = teams.map(&:all_club_ids).flatten.compact.uniq
    # get hosting clubs
    all_club_ids = [club_ids, league.game_days.map(&:club_id)].flatten.compact.uniq

    # Rollen additiv: sonst blockiert eine nicht passende VM-Rolle den
    # TM-Zweig, obwohl der Nutzer über sein Team berechtigt wäre.
    allowed = ph[:admin].present? || sbk_can_access_leagues?(ph, [league]) ||
              # vm: permission for one of those clubs?
              (ph[:vm].present? && ph[:vm].intersection(all_club_ids).present?) ||
              # tm: get clubs for league teams of given team, permission for one of those?
              (ph[:tm].present? && ph[:tm].intersection(teams.map(&:id)).present?)

    if allowed
      render json: league.licenses(true)
    else
      render json: { message: 'Keine Berechtigung!' }, status: :forbidden
    end
  end

  def withdraw_license_request
    player = Player.find(params[:id])

    player.licenses.each { |l| l['id'] ||= l.delete('_id') }
    found_license = player.licenses.find { |l| l['id'] == params[:license_id] }
    return render json: { message: 'Lizenz nicht gefunden.' }, status: :not_found unless found_license

    team = Team.find(found_license['team_id'])
    ph = current_user.permission_hash
    allowed = may_manage_team?(ph, team)
    return render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden unless allowed

    last_status_id = found_license['history'].max_by { |h| h['created_at'] }&.dig('license_status_id').to_i
    unless last_status_id == License::REQUESTED
      return render json: { message: 'Nur beantragte Lizenzen können zurückgezogen werden.' },
                    status: :unprocessable_entity
    end

    last_requested = found_license['history']
                       .select { |h| h['license_status_id'].to_i == License::REQUESTED }
                       .max_by { |h| h['created_at'] }

    if last_requested && (Time.now - last_requested['created_at'].to_time) < License::GRACE_PERIOD
      player.licenses.reject! { |l| l['id'] == params[:license_id] }
      if player.save
        render json: { success: true, grace_period_deletion: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      meta_user_license_change(License::WITHDRAWN)
    end
  end

  def reenable_license_request
    meta_user_license_change(License::REQUESTED)
  end

  def meta_user_license_change(status)
    # hole spieler
    player = Player.find(params[:id])

    found_license = nil
    player.licenses.map! do |license|
      if license['_id'].present?
        license['id'] = license['_id']
        license['_id'] = nil
      end
      if license['id'] == params[:license_id]
        found_license = license

        license['history'] << {
          license_status_id: status,
          created_by: current_user.id,
          created_at: Time.now
        }
      end

      license
    end

    # prüfe ob user lizenz für team beantragen darf
    team = Team.find(found_license['team_id'])

    ph = current_user.permission_hash
    allowed = may_manage_team?(ph, team)

    if allowed
      if player.save
        render json: { success: true }
      else
        render json: { message: player.errors }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung für dieses Team!' }, status: :forbidden
    end
  end

  def admin_player_update
    if current_user
      create_modus = params[:id].zero?
      # check: game operation permission if create_modus
      #   has: create team for that go?
      #   else : unpermitted!
      # check: league permission unless create_modus
      #   has: update league for that league?
      #   else : unpermitted!
      if create_modus && Club.find(params[:club_id])&.user_permissions(current_user)&.include?(:create_player) # create

        if params['first_name'].blank? || params['last_name'].blank? || params['birthdate'].blank?
          return render json: { message: 'Vorname, Nachname und Geburtsdatum sind erforderlich.' }, status: :unprocessable_entity
        end

        begin
          birthdate = params['birthdate'].to_date
        rescue ArgumentError, TypeError
          return render json: { message: 'Ungültiges Geburtsdatum.' }, status: :unprocessable_entity
        end

        first_name = "%#{params['first_name'].to_s.downcase.strip}%"
        last_name = "%#{params['last_name'].to_s.downcase.strip}%"
        existing_player_id = Player.where('first_name ILIKE ? AND last_name ILIKE ? AND birthdate = ?', first_name,
                                          last_name, birthdate).limit(1).pluck(:id).first

        if existing_player_id.present?
          render json: { message: "Es existiert ein Spieler mit diesen Daten (ID: #{existing_player_id}). Anlegen nicht möglich." },
                 status: :unprocessable_entity
        else
          pp = player_params
          player = Player.new(pp)
          player.clubs = [{
            club_id: params[:club_id].to_i,
            home_club: true,
            created_at: Time.now,
            created_by: current_user.id
          }]
          player.created_by = current_user.id

          player.save

          render json: player, status: :created
        end
      elsif !create_modus && Club.find(params[:club_id])&.user_permissions(current_user)&.include?(:update_player) # update
        # update
        player = Player.find(params[:id])
        # IDOR-Schutz: Die :update_player-Berechtigung wird gegen params[:club_id]
        # geprüft – der Spieler muss auch tatsächlich diesem Verein angehören,
        # sonst ließe sich über einen beliebigen eigenen Verein jeder Spieler
        # überschreiben.
        unless (player.clubs || []).any? { |c| c['club_id'].to_i == params[:club_id].to_i }
          return render json: { message: 'Spieler gehört nicht zu diesem Verein.' }, status: :forbidden
        end

        player.updated_by = current_user.id
        if player.update(player_params)
          render json: player
        else
          render json: player.errors, status: :unprocessable_entity
        end
      else
        render json: { message: 'Keine Berechtigung' }, status: :forbidden
      end

    else
      render json: { message: 'Nicht eingeloggt.' }, status: :unauthorized
    end
  end

  def add_additional_club
    # hole spieler
    player = Player.find(params[:id])
    club = Club.find(params[:club_id])

    ph = current_user.permission_hash

    if ph[:admin].present? || sbk_may_move_player?(ph, player, club)

      # if player and club present, we check if the club.id is already in the players clubs hash
      if player.present? &&
         club.present?

        if !player.clubs.select do |c|
              c['valid_until'].nil? || c['valid_until'].to_date > Date.today
            end.map do |c|
             c['club_id']
           end.include?(club.id)
          # valid until next 15.07.20XX
          valid_until = Date.new(Date.today.year, 7, 15).to_time
          valid_until += 1.year if valid_until < Time.now

          club_entry = {
            club_id: club.id,
            home_club: false,
            created_by: current_user.id,
            valid_set_by: current_user.id,
            created_at: Time.now,
            valid_until:
          }
          # add club to clubs array
          player.clubs << club_entry

          if player.save
            render json: { success: true }
          else
            render json: { message: player.errors }, status: :unprocessable_entity
          end
        else
          render json: { message: 'Spieler bereits in dem Verein vorhanden' }, status: :unprocessable_entity
        end
      else
        render json: { message: 'Verein oder Spieler nicht gefunden' }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def remove_additional_club
    # hole spieler
    player = Player.find(params[:id])
    club = Club.find(params[:club_id])

    ph = current_user.permission_hash

    if ph[:admin].present? || ph[:sbk].present?

      # if player and club present, we check if the club.id is already in the players clubs hash
      if player.present? &&
         club.present?

        player.clubs.map! do |c|
          # additional club == ! home
          # entry only for given club
          # valid_until should always be present in this case, check to avoid errors and only check for current entries
          if !c['home_club'] &&
             c['club_id'] == club.id &&
             c['valid_until'].present? && c['valid_until'].to_time > Time.now && c['valid_until'] == params[:valid_until]
            c['valid_until'] = Time.now
            c['valid_set_by'] = current_user.id
          end

          c
        end

        if player.save
          render json: { success: true }
        else
          render json: { message: player.errors }, status: :unprocessable_entity
        end
      else
        render json: { message: 'Verein oder Spieler nicht gefunden' }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def transfer
    # hole spieler
    player = Player.find(params[:id])
    club = Club.find(params[:club_id])

    ph = current_user.permission_hash

    if ph[:admin].present? || sbk_may_move_player?(ph, player, club)

      # if player and club present, we check if the club.id is already in the players clubs hash
      if player.present? &&
         club.present?

        if !player.clubs.select do |c|
              c['valid_until'].nil? || c['valid_until'].to_date > Date.today
            end.map do |c|
             c['club_id']
           end.include?(club.id)

          current_teams = club.current_teams
          current_licenses = (player.current_licenses || []).reject do |l|
                               [6, 7].include?(l['history'].last['license_status_id'].to_i)
                             end.map { |l| l['team_id'] }

          # check for licenses for that club
          if current_licenses.empty?

            old_club_id = nil

            player.clubs.map! do |c|
              # if it's a current entry for the home_club
              if c['valid_until'].nil? && c['home_club']
                c['valid_until'] = Time.now
                c['valid_set_by'] = current_user.id

                old_club_id = c['club_id']
              end

              c
            end

            new_club_entry = {
              club_id: club.id,
              home_club: true,
              created_by: current_user.id,
              created_at: Time.now
            }

            # add club to clubs array
            player.clubs << new_club_entry

            if old_club_id.present?
              transfer = Transfer.new({
                                        created_by: current_user.id,
                                        former_club_id: old_club_id,
                                        new_club_id: club.id,
                                        player_id: player.id,
                                        season_id: Setting.current_season_id
                                      })

              success = false

              Player.transaction do
                transfer.save!
                player.save!

                success = true
              end

              if success
                render json: { success: true }
              else
                render json: { message: player.errors }, status: :unprocessable_entity
              end
            else
              render json: { message: 'Konnte alten Verein nicht finden. Abbruch.' },
                     status: :unprocessable_entity
            end
          else
            render json: { message: "Spieler hat für diesen Verein eine Lizenz (Team: #{current_licenses.join ','})" },
                   status: :unprocessable_entity
          end

        else
          render json: { message: 'Spieler bereits in dem Verein vorhanden' }, status: :unprocessable_entity
        end
      else
        render json: { message: 'Verein oder Spieler nicht gefunden' }, status: :unprocessable_entity
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def stats
    player = Player.find(params[:id])
    setting = Setting.current
    seasons_map = setting.seasons.each_with_object({}) { |(k, v), h| h[k.to_i] = v['name'] }
    current_season_id = Setting.current_season_id.to_i

    # Abgeschlossene Saisons sind unveränderlich → lange TTL. Der Key trägt
    # die aktuelle Saison, damit beim Saisonwechsel die bis dahin laufende
    # Saison automatisch in den Langzeit-Cache nachrückt. Die laufende Saison
    # ändert sich mit jedem abgeschlossenen Spielbericht → kurze TTL.
    closed_seasons = Rails.cache.fetch("players/#{player.id}/stats/closed/#{current_season_id}", expires_in: 1.week) do
      stats_by_season(player.id, current_season_id, current_season: false)
    end
    current_season = Rails.cache.fetch("players/#{player.id}/stats/current/#{current_season_id}",
                                       expires_in: 15.minutes) do
      stats_by_season(player.id, current_season_id, current_season: true)
    end

    by_season = closed_seasons.merge(current_season)

    # Anzeige-Namen (Liga/Verband/Team) werden NICHT gecacht, sondern frisch
    # aufgelöst — analog zu season_name. So bleiben Umbenennungen sofort
    # sichtbar, obwohl die (numerischen) Aggregate lange gecacht sind.
    league_ids = by_season.values.flat_map(&:keys).uniq
    leagues_by_id = League.where(id: league_ids).includes(:game_operation).index_by(&:id)
    team_ids = by_season.values.flat_map { |leagues| leagues.values.map { |e| e[:team_id] } }.compact.uniq
    team_names = Team.where(id: team_ids).pluck(:id, :name).to_h

    seasons = by_season
              .sort_by { |season_id, _| -season_id }
              .map do |season_id, leagues|
      sorted = leagues.values.sort_by { |e| -e[:games] }
      league_entries = sorted.map { |entry| entry_with_names(entry, leagues_by_id, team_names) }
      {
        season_id:,
        season_name: seasons_map[season_id] || season_id.to_s,
        leagues:     league_entries
      }
    end

    total_games   = seasons.sum { |s| s[:leagues].sum { |l| l[:games] } }
    total_goals   = seasons.sum { |s| s[:leagues].sum { |l| l[:goals] } }
    total_assists = seasons.sum { |s| s[:leagues].sum { |l| l[:assists] } }
    last_season   = seasons.first

    # Bewusst ohne birthdate und gender: Der Endpunkt ist per X-Api-Key
    # erreichbar und die Spieler-ID frei durchzählbar, ein Geburtsdatum je Name
    # wäre damit für den gesamten Spielerbestand abrufbar. Die öffentliche
    # Spielerseite zeigt beides ohnehin nicht an.
    render json: {
      player: {
        id:             player.id,
        first_name:     player.first_name,
        last_name:      player.last_name,
        deactivated_at: player.deactivated_at
      },
      seasons:,
      totals: {
        games:          total_games,
        goals:          total_goals,
        assists:        total_assists,
        scorer_points:  total_goals + total_assists,
        scorer_per_game: total_games > 0 ? ((total_goals + total_assists).to_f / total_games).round(2) : 0,
        last_season:    last_season&.dig(:season_name)
      }
    }
  end

  def transfers_public
    result = Rails.cache.fetch('transfers', expires_in: 30.minutes) do
      Transfer.includes(:former_club, :new_club, :player).where(season_id: Setting.current_season_id).map(&:as_json)
    end

    render json: result
  end

  # POST /admin/players/:id/deactivate
  def merge
    master = Player.find_by(id: params[:id])
    return render json: { message: 'Master-Spieler nicht gefunden.' }, status: :not_found unless master

    secondary = Player.find_by(id: params[:secondary_id])
    return render json: { message: 'Secondary-Spieler nicht gefunden.' }, status: :not_found unless secondary

    ph = current_user.permission_hash
    unless ph[:admin].present? || (sbk_can_access_player?(ph, master) && sbk_can_access_player?(ph, secondary))
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    secondary.merge_into!(master, current_user.id)
    render json: { message: 'Spieler erfolgreich zusammengeführt.', master_id: master.id }
  rescue ArgumentError => e
    render json: { message: e.message }, status: :unprocessable_entity
  end

  def deactivate
    player = Player.find_by(id: params[:id])
    return render json: { message: 'Spieler nicht gefunden.' }, status: :not_found unless player
    return render json: { message: 'Spieler ist bereits deaktiviert.' }, status: :unprocessable_entity if player.deactivated_at.present?
    return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless can_manage_player?(player)

    reason = sanitize_deactivation_reason(params[:reason])
    return render json: { message: 'Ungültiger Deaktivierungsgrund.' }, status: :unprocessable_entity if reason == :invalid

    player.deactivate!(current_user.id, reason: reason)
    render json: player.full_hash(false, false, false)
  end

  def reactivate
    player = Player.find_by(id: params[:id])
    return render json: { message: 'Spieler nicht gefunden.' }, status: :not_found unless player
    return render json: { message: 'Spieler ist nicht deaktiviert.' }, status: :unprocessable_entity if player.deactivated_at.nil?

    # Wer deaktivieren darf, muss zurücknehmen können: deactivate! stempelt auch
    # die Heimat-Zugehörigkeit, weshalb die reguläre Prüfung ab dem Tag danach
    # nein sagt (siehe sbk_can_undo_deactivation?).
    ph = current_user.permission_hash
    unless ph[:admin].present? || sbk_can_access_player?(ph, player) ||
           vm_can_access_player?(ph, player) || tm_can_access_player?(ph, player) ||
           sbk_can_undo_deactivation?(ph, player)
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    # Eine zusammengefuehrte Dublette ist nur deshalb deaktiviert, weil merge_into!
    # sie ersetzt hat; Spiele und Lizenzen liegen beim Master. Reaktiviert waere sie
    # wieder ein zweites Profil derselben Person.
    if player.merged_into_id.present?
      return render json: { message: 'Dieses Profil wurde mit einem anderen zusammengeführt und kann nicht reaktiviert werden.' },
                    status: :unprocessable_entity
    end

    player.reactivate!
    render json: player.full_hash(false, false, false)
  end

  def vm_players_index
    ph = current_user.permission_hash
    club_id = params[:club_id]&.to_i
    return render json: { message: 'club_id fehlt.' }, status: :bad_request unless club_id.present? && club_id > 0

    sbk_ok = ph[:sbk].present? && (ph[:sbk].include?(0) || derive_club_ids_for_go(ph[:sbk]).include?(club_id))
    allowed = ph[:admin].present? || sbk_ok ||
              (ph[:vm].present? && ph[:vm].include?(club_id)) ||
              tm_can_access_club?(ph, club_id)
    return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless allowed

    club = Club.find_by(id: club_id)
    return render json: { message: 'Verein nicht gefunden.' }, status: :not_found unless club

    # Ueber Club#players: abgelaufene Freigaben bleiben draussen (der fruehere Roh-Query
    # clubs @> {club_id} ignorierte valid_until und zeigte sie weiterhin an).
    # Deaktivierte kommen mit, damit sie in der VM-Spielerliste hinter dem Schalter
    # sichtbar und von dort reaktivierbar bleiben.
    players = club.players(include_deactivated: true)
    leagues_by_team = Team.joins(:league)
                          .where(leagues: { season_id: Setting.current_season_id })
                          .pluck(:id, 'leagues.id', 'leagues.short_name', 'leagues.name')
                          .to_h { |team_id, league_id, short_name, name| [team_id, { id: league_id, short_name: short_name.presence || name }] }

    render json: players.map { |p|
      base = p.meta_hash
      current_lics = (p.licenses || []).select { |l| leagues_by_team.key?(l['team_id'].to_i) }
      if current_lics.present?
        # Ein Eintrag pro Liga-Lizenz der laufenden Saison, höchste Liga zuerst;
        # der erste Eintrag speist die bestehenden current_license_status-Felder.
        sorted = current_lics.sort_by { |l| [League.class_rank(l['league_class_id']), License.approval_time(l)] }
        entries = sorted.filter_map do |l|
          status_id = l['history']&.max_by { |h| h['created_at'] }&.dig('license_status_id')&.to_i
          next unless status_id && License::NAMES.key?(status_id)

          league = leagues_by_team[l['team_id'].to_i]
          { license_status_id: status_id, license_status: License::NAMES[status_id],
            league_id: league[:id], league_short_name: league[:short_name] }
        end
        entries.uniq! { |e| [e[:league_id], e[:license_status_id]] }
        if entries.present?
          base[:current_licenses] = entries
          base[:current_license_status_id] = entries.first[:license_status_id]
          base[:current_license_status] = entries.first[:license_status]
        end
      end
      base
    }
  end

  def update_email
    player = Player.find_by(id: params[:id])
    return render json: { message: 'Spieler nicht gefunden.' }, status: :not_found unless player
    return render json: { message: 'Keine Berechtigung.' }, status: :forbidden unless can_manage_player?(player)

    email = params[:email].is_a?(String) ? params[:email].presence : nil
    if email && !URI::MailTo::EMAIL_REGEXP.match?(email)
      return render json: { message: 'Ungültige E-Mail-Adresse.' }, status: :unprocessable_entity
    end

    if player.update(email: email)
      render json: { id: player.id, email: player.email }
    else
      render json: { message: player.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private

  # season_id → league_id → aggregierte Stats aus allen beendeten Spielen mit
  # diesem Spieler in der Aufstellung. current_season: true rechnet nur die
  # laufende Saison, false alle übrigen (inkl. Ligen ohne season_id — deren
  # Wert landet wie bisher unter season_id 0).
  def stats_by_season(player_id, current_season_id, current_season:)
    # Top-Level-Containment (players @> …) statt players->'home' @> …, damit
    # der GIN-Index auf games.players greift (Expression-Queries nutzen einen
    # Spalten-Index nicht).
    games = Game
            .joins(game_day: { league: :game_operation })
            .where(ended: true)
            .where(
              'players @> ? OR players @> ?',
              { home: [{ player_id: player_id.to_i }] }.to_json,
              { guest: [{ player_id: player_id.to_i }] }.to_json
            )
    # leagues.season_id ist eine String-Spalte.
    games = if current_season
              games.where(leagues: { season_id: current_season_id.to_s })
            else
              games.where('leagues.season_id IS NULL OR leagues.season_id <> ?', current_season_id.to_s)
            end
    games = games.includes(game_day: { league: :game_operation })

    by_season = {}

    games.each do |game|
      scorer_data = game.evaluate_scorer[player_id]
      next if scorer_data.nil?

      league      = game.game_day.league
      season_id   = league.season_id.to_i
      league_id   = league.id

      by_season[season_id] ||= {}
      # Nur numerische Aggregate + IDs cachen — Anzeige-Namen löst #stats
      # frisch auf (siehe entry_with_names), damit Umbenennungen nicht bis
      # zum TTL-Ablauf stale bleiben.
      entry = by_season[season_id][league_id] ||= {
        league_id:,
        team_id: scorer_data[:team_id],
        games: 0, goals: 0, assists: 0, penalty_minutes: 0
      }

      entry[:games]           += 1
      entry[:goals]           += scorer_data[:goals]
      entry[:assists]         += scorer_data[:assists]
      entry[:penalty_minutes] += (scorer_data[:penalty_2]       * 2) +
                                 (scorer_data[:penalty_2and2]   * 4) +
                                 (scorer_data[:penalty_5]       * 5) +
                                 (scorer_data[:penalty_10]      * 10) +
                                 (scorer_data[:penalty_ms_tech] + scorer_data[:penalty_ms_full] +
                                  scorer_data[:penalty_ms1]     + scorer_data[:penalty_ms2] +
                                  scorer_data[:penalty_ms3]) * 25
    end

    by_season
  end

  # Reichert einen gecachten (rein numerischen) Liga-Eintrag mit frisch
  # aufgelösten Anzeige-Namen an.
  def entry_with_names(entry, leagues_by_id, team_names)
    league = leagues_by_id[entry[:league_id]]
    entry.merge(
      league_name:    league&.name,
      league_slug:    league && "#{league.id}-#{league.short_name&.parameterize}",
      game_operation: league&.game_operation&.short_name,
      team_name:      team_names[entry[:team_id]]
    )
  end

  def can_manage_player?(player)
    ph = current_user.permission_hash
    ph[:admin].present? || sbk_can_access_player?(ph, player) ||
      vm_can_access_player?(ph, player) || tm_can_access_player?(ph, player)
  end

  def vm_can_access_player?(ph, player)
    return false unless ph[:vm].present?

    player.clubs.any? { |c| ph[:vm].include?(c['club_id'].to_i) }
  end

  def tm_can_access_player?(ph, player)
    club_ids = tm_club_ids(ph)
    return false if club_ids.empty?

    player.clubs.any? { |c| club_ids.include?(c['club_id'].to_i) }
  end

  def tm_can_access_club?(ph, club_id)
    tm_club_ids(ph).include?(club_id)
  end

  def tm_club_ids(ph)
    return [] unless ph[:tm].present?

    Team.current_season.where(id: ph[:tm]).flat_map(&:all_club_ids).uniq
  end

  def sanitize_deactivation_reason(raw)
    value = raw.is_a?(String) ? raw.strip.slice(0, 255) : nil
    return nil if value.blank?
    # Player::DEACTIVATION_REASONS ist die gemeinsame Quelle: reactivate! muss
    # genau die Gründe erkennen, die hier durchkommen, sonst bleibt beim
    # Reaktivieren der Lizenz-Verlauf auf "gelöscht" stehen.
    return value if Player::DEACTIVATION_REASONS.include?(value)
    return value if value.start_with?('Sonstiges: ') && value[11..].strip.present?

    :invalid
  end

  # Der clubs-Hash enthält nach jedem Heimatvereinswechsel MEHRERE Einträge mit
  # home_club: true – der alte bekommt ein valid_until gestempelt, der neue kommt
  # hinten dran. Ein ungefiltertes find traf deshalb den abgelaufenen Alt-Eintrag
  # und prüfte dessen Spielbetrieb gegen den Scope: Wer aus einem anderen Verband
  # (oder einem Ablage-Verein) zugezogen war, blieb für die eigene SBK gesperrt.
  # Player#home_club verwirft abgelaufene Einträge und nimmt den letzten
  # gültigen, ist also die kanonische Quelle für den Heimatverein.
  #
  # Ohne gültige Heimat-Zugehörigkeit bleibt das Profil für die Landes-SBK
  # gesperrt. Das ist entschieden (api#389): ein Datenproblem, das über die
  # Datenpflege gelöst wird, nicht über die Rechteregel. Einzige Ausnahme ist die
  # Rücknahme einer Deaktivierung, siehe sbk_can_undo_deactivation?.
  def sbk_can_access_player?(ph, player)
    return false unless ph[:sbk].present?
    return true if ph[:sbk].include?(0)

    home_club = player.home_club(Date.today)
    return false unless home_club

    ph[:sbk].include?(home_club.main_game_operation_id)
  end

  # Darf diese Stelle den Spieler in DIESEN Verein setzen (transfer,
  # add_additional_club)?
  #
  # Beide Aktionen prüften vorher nur, OB jemand eine Spielbetriebsrolle hat,
  # nicht WELCHEN Spielbetrieb. Eine auf einen Verband beschränkte Rolle konnte
  # damit ein beliebiges fremdes Profil in einen Verein des eigenen Verbands
  # transferieren — und war danach über den frisch geschriebenen
  # `home_club: true` regulär für dieses Profil zuständig. Die Verschärfungen aus
  # #391 und #394 begrenzten damit nur den bequemen Weg, nicht den Zugriff.
  #
  # Zwei Bedingungen, beide nötig:
  #
  #   (a) Zuständigkeit für den Spieler VORHER, also über seinen aktuell
  #       gültigen Heimatverein. Ohne (a) bleibt der Transfer der Weg, sich
  #       Zuständigkeit überhaupt erst zu verschaffen.
  #   (b) Der ZIELVEREIN liegt im eigenen Spielbetrieb.
  #
  # Damit gilt für eine Landes-SBK genau die fachliche Regel: direkt bewegen darf
  # sie nur, wenn Heimat- UND Zielverein in ihrem Spielbetrieb liegen. Der Wechsel
  # über Spielbetriebe hinweg läuft über den Transferantrag (`TransferRequest`)
  # mit LV-Freigabe oder über die bundesweite SBK.
  #
  # Ein Profil ohne gültigen Heimatverein (Altbestand, deaktiviert) fällt durch
  # (a) und bleibt damit Admin und bundesweiter SBK vorbehalten. Das ist kein
  # Sonderfall des Alltags: Jeder Weg, der eine Heimat-Mitgliedschaft schließt
  # (`transfer` hier, `Player#transfer`, die TransferRequest-Verarbeitung), öffnet
  # im selben Vorgang die neue. Vereinslos wird ein Profil nur durch
  # `deactivate!`, und dort ist die Antwort `reactivate`. Für die verbleibenden
  # Altfälle ist die Zuständigkeit ohnehin nicht eindeutig bestimmbar, siehe #399.
  #
  # (b) über `readable_by_game_operations?` und nicht über einen reinen Vergleich
  # mit `main_game_operation_id`: Eine Vereins-Freigabe des besitzenden
  # Landesverbands (`StateAssociationRelease`, saisonweise und ausdrücklich
  # erteilt) zählt mit, so wie überall sonst, wo über die Erreichbarkeit eines
  # Vereins entschieden wird. Sie erweitert nur, wohin die eigenen Spieler dürfen;
  # fremde Profile schützt weiterhin (a).
  def sbk_may_move_player?(ph, player, club)
    return false unless sbk_can_access_player?(ph, player)
    return true if ph[:sbk].include?(0)

    club.readable_by_game_operations?(ph[:sbk])
  end

  # Darf diese Stelle eine Deaktivierung zurücknehmen?
  #
  # Das Problem: `Player#deactivate!` stempelt ALLE Zugehörigkeiten, auch die
  # Heimat. Ab dem Tag danach findet `sbk_can_access_player?` keinen gültigen
  # Heimatverein mehr und sagt nein — eine Landes-SBK durfte deaktivieren, aber
  # ihre eigene Entscheidung nicht zurücknehmen (gemessen, nicht vermutet).
  #
  # Die Regel ist deshalb nicht „irgendein früherer Heimatverein", sondern:
  # **Zuständig ist, wer für das Profil zuständig WÄRE, sobald es wieder aktiv
  # ist.** Also genau die reguläre Prüfung, angewandt auf den Stand, den
  # `reactivate!` herstellt. Das macht drei Fehlerquellen gegenstandslos, an denen
  # frühere Fassungen dieses Zweigs gescheitert sind:
  #
  #   - Kein ODER über mehrere geschlossene Einträge. `deactivate!` schließt auch
  #     eine offene Altlast-Heimat eines fremden Verbands; die zählte sonst mit und
  #     verschaffte diesem Verband Zugriff samt `full_hash`.
  #   - Kein Sortieren nach `valid_until`. Diese Werte sind nach einer
  #     Deaktivierung identisch (alle in derselben Millisekunde gestempelt), der
  #     Vergleich fiel also auf die Array-Position zurück — und die ist nicht
  #     chronologisch (`Player#_merge_clubs` sortiert nach `created_at`).
  #   - Keine zweite Definition von „Heimatverein". Maßgeblich ist dieselbe
  #     Methode, die auch nach der Rücknahme gilt.
  #
  # Wer nach der Rücknahme nicht zuständig wäre, hat hier nichts zu entscheiden:
  # `reactivate` antwortet mit `full_hash`, ein weiter gefasster Zweig wäre also
  # ein Lesepfad auf die Profildaten, die api#389 zurückhält.
  def sbk_can_undo_deactivation?(ph, player)
    return false unless ph[:sbk].present?
    return true if ph[:sbk].include?(0)

    sbk_can_access_player?(ph, player_after_reactivation(player))
  end

  # Der Spieler, wie er nach `reactivate!` aussähe: Zugehörigkeiten, die DIESE
  # Deaktivierung geschlossen hat, sind wieder offen. Nur eine Kopie im Speicher,
  # nichts wird gespeichert.
  #
  # `restore_membership_validity` ist private, deshalb hier dieselbe Wirkung: das
  # gestempelte `valid_until` entfernen bzw. auf die vor der Deaktivierung
  # gesicherte Befristung zurücksetzen (Player::VALID_BEFORE_DEACTIVATION).
  def player_after_reactivation(player)
    # Keine id setzen: Der Prüfpfad liest sie nicht, und ohne sie kann die Kopie
    # nirgends mit einem gespeicherten Datensatz verwechselt werden.
    restored = player.dup
    restored.clubs = (player.clubs || []).map do |entry|
      next entry unless player.membership_closed_by_deactivation?(entry)

      copy = entry.deep_dup
      saved = copy.delete(Player::VALID_BEFORE_DEACTIVATION)
      copy['valid_until'] = saved && saved['valid_until']
      copy
    end
    restored
  end

  def derive_club_ids_for_go(go_ids)
    Club.all.select { |c| go_ids.include?(c.main_game_operation_id) }.map(&:id)
  end

  def set_player
    @player = Player.find(params[:id])
  end

  def player_params
    params.require(:player).permit(:birthdate, :first_name, :last_name, :gender, :nation_id, :email)
  end

  def default_license_valid_until(season_id)
    season = Setting.current.seasons[season_id.to_s]
    end_year = if season
                 first_year = season['name'].to_s.split('/').first.to_i
                 first_year.positive? ? first_year + 1 : Date.today.year
               else
                 Date.today.year
               end
    Date.new(end_year, 7, 31)
  end
end
