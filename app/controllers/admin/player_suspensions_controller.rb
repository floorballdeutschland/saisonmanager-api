module Admin
  class PlayerSuspensionsController < ApplicationController
    # sbk_can_access_team? / sbk_can_access_license? / sbk_global? – Scope über
    # die Liga, nicht über den Verein.
    include LicenseAccessScope

    before_action :set_player
    before_action :check_read_permission, only: %i[index]
    before_action :check_suspend_permission, only: %i[create destroy]

    def index
      @player.expire_due_suspensions!
      render json: @player.suspensions.order(created_at: :desc).map { |s| suspension_json(s) }
    end

    def create
      valid_until = parse_date(params[:valid_until])
      if params[:valid_until].present? && valid_until.nil?
        return render json: { message: 'Ablaufdatum ungültig.' }, status: :unprocessable_entity
      end

      games_total = params[:games_total].presence&.to_i
      if valid_until.nil? && games_total.nil?
        return render json: { message: 'Eine Sperre braucht ein Enddatum oder eine Anzahl von Spielen.' },
                      status: :unprocessable_entity
      end

      scope_kind = suspension_scope_kind
      if scope_kind == PlayerSuspension::SCOPE_COMPETITION && scope_league.blank?
        return render json: { message: 'Für eine Sperre auf einen Wettbewerb fehlt die Liga, aus der sie stammt.' },
                      status: :unprocessable_entity
      end

      suspension = @player.suspend!(
        user_id: current_user.id,
        team_id: params[:team_id].presence,
        scope: { kind: scope_kind, league: scope_league,
                 competition_groups: params[:competition_groups],
                 all_game_operations: all_game_operations? },
        valid_from: parse_date(params[:valid_from]) || Date.current,
        valid_until:,
        games_total:,
        reason: params[:reason].presence
      )

      render json: suspension_json(suspension), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { message: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    # Manuelles Aufheben durch Admin oder SBK. Der Grund landet in der
    # Lizenzhistorie, damit im Verlauf steht, warum die Lizenz vor dem Ablauf
    # der Sperre wieder gilt.
    def destroy
      suspension = @player.suspensions.find(params[:id])
      reason = params[:reason].presence
      @player.lift_suspension!(suspension, user_id: current_user.id,
                                           reason: reason ? "Sperre aufgehoben: #{reason}" : 'Sperre aufgehoben')
      render json: suspension_json(suspension.reload)
    end

    private

    # Eine Wettbewerbssperre ohne Spielbetriebs-Grenze greift in JEDEM Verband
    # derselben Altersklasse. Die SBK hat ihre Weisungsbefugnis nur im eigenen
    # Spielbetrieb, deshalb bleibt die Entgrenzung der Bundesadministration und
    # der globalen SBK-Rolle vorbehalten -- der Wunsch allein genuegt nicht,
    # sonst waere die Grenze eine Bitte und keine Regel.
    def all_game_operations?
      return false unless ActiveModel::Type::Boolean.new.cast(params[:all_game_operations])

      ph = current_user.permission_hash
      ph[:admin].present? || sbk_global?(ph)
    end

    def set_player
      @player = Player.find(params[:player_id])
    end

    def check_read_permission
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if sbk_may_read?(ph)

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    def check_suspend_permission
      ph = current_user.permission_hash
      return if ph[:admin].present?
      return if sbk_may_suspend?(ph)

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    # LESEN: dieselbe Regel wie bei den Lizenzdokumenten – ein Verein des
    # Spielers ist über den zustaendigen Spielbetrieb oder eine Vereins-Freigabe
    # lesbar, oder eine seiner Lizenzen hängt an einer Liga des eigenen
    # Spielbetriebs.
    def sbk_may_read?(perm_hash)
      return false if perm_hash[:sbk].blank?
      return true if sbk_global?(perm_hash)
      return true if player_clubs_readable?(perm_hash)

      (@player.licenses || []).any? { |l| sbk_can_access_license?(perm_hash, l) }
    end

    # SPERREN: Eine spielerweite Sperre blockiert *alle* Lizenzanträge, wirkt
    # also weit über den eigenen Spielbetrieb hinaus. Sie darf deshalb nur der
    # Heimatverband des Spielers setzen und aufheben – der Spielbetrieb, der fuer
    # seinen Verein zustaendig ist.
    #
    # Eine Vereins-Freigabe reicht dafür ausdrücklich NICHT: Sie gewährt nur
    # Lesezugriff (siehe StateAssociationRelease und Club#user_permissions, wo
    # :update_club ebenfalls am zustaendigen Spielbetrieb hängt).
    #
    # Bezieht sich die Sperre dagegen auf eine einzelne Team-Lizenz, zählt
    # zusätzlich die Liga dieses Teams: Wer die Lizenz erteilt, darf sie auch
    # aussetzen – dieselbe Quelle wie in LicenseAccessScope.
    #
    # Vorher wurde gegen den GESAMTEN game_operations_hash aller Vereine des
    # Spielers geprüft, also auch gegen bloße Gast-Einträge aus dem
    # Altdaten-Import 2010–2014. Damit hätte ein Landesverband Spieler fremder
    # Vereine sperren können, ohne dass es jemand erteilt hätte. Das war die
    # letzte Stelle, die den Hash für eine Rechteentscheidung gelesen hat.
    #
    # Seit #604 haengt die Antwort am Geltungsbereich: `all` und `competition`
    # reichen ueber den eigenen Spielbetrieb hinaus (eine Wettbewerbssperre
    # greift in jeder Liga derselben Altersklasse, auch in fremden Verbaenden)
    # und bleiben deshalb dem Heimatverband vorbehalten. `league` und `team`
    # darf auch der Verband der betroffenen Liga setzen.
    def sbk_may_suspend?(perm_hash)
      return false if perm_hash[:sbk].blank?
      return true if sbk_global?(perm_hash)
      return true if (perm_hash[:sbk] & player_home_game_operation_ids).present?

      case suspension_scope_kind
      when PlayerSuspension::SCOPE_TEAM then sbk_may_suspend_team?(perm_hash)
      when PlayerSuspension::SCOPE_LEAGUE then sbk_may_suspend_league?(perm_hash)
      else false
      end
    end

    def sbk_may_suspend_team?(perm_hash)
      team = Team.find_by(id: suspension_scope_team_id)
      return false if team.blank?
      return false unless sbk_can_access_team?(perm_hash, team)

      # Das Team muss auch zum Spieler gehören. Ohne diese Schranke würde die
      # team_id aus den Parametern genügen: Eine SBK könnte ein beliebiges Team
      # ihrer eigenen Liga angeben und damit eine Sperre auf einen *fremden*
      # Spieler schreiben, mit dem dieses Team nichts zu tun hat. Über
      # Player#suspended_for_team? liesse sich dieser Spieler dann dauerhaft von
      # einer Lizenz für dieses Team aussperren.
      #
      # Dieselbe Schranke wie in PlayersController#request_license (Z. 138),
      # dort mit derselben Begründung.
      player_in_team_clubs?(@player, team) ||
        (@player.licenses || []).any? { |l| l['team_id'].to_i == team.id }
    end

    # Wie bei der Team-Sperre: Der Spielbetrieb der Liga genuegt, aber der
    # Spieler muss mit dieser Liga zu tun haben. Ohne die zweite Schranke
    # koennte eine SBK eine beliebige eigene Liga angeben und damit eine Sperre
    # auf einen fremden Spieler schreiben.
    def sbk_may_suspend_league?(perm_hash)
      league = scope_league
      return false if league.blank?
      return false unless perm_hash[:sbk].include?(league.game_operation_id)

      league_team_ids = Team.where(league_id: league.id)
                            .or(Team.where('cup_leagues && ARRAY[?]::int[]', [league.id]))
                            .pluck(:id)
      return false if league_team_ids.empty?

      (@player.licenses || []).any? { |l| league_team_ids.include?(l['team_id'].to_i) } ||
        Team.where(id: league_team_ids).any? { |t| player_in_team_clubs?(@player, t) }
    end

    # Der Geltungsbereich der Anfrage. Beim Anlegen aus den Parametern, beim
    # Aufheben aus der bestehenden Sperre.
    def suspension_scope_kind
      if action_name == 'create'
        kind = params[:scope_kind].presence
        return kind if PlayerSuspension::SCOPE_KINDS.include?(kind)

        return params[:team_id].presence ? PlayerSuspension::SCOPE_TEAM : PlayerSuspension::SCOPE_ALL
      end

      @player.suspensions.find_by(id: params[:id])&.scope_kind
    end

    # Die Liga, aus der eine Wettbewerbs- oder Ligasperre stammt.
    def scope_league
      return @scope_league if defined?(@scope_league)

      @scope_league = League.find_by(id: params[:league_id]) if params[:league_id].present?
      @scope_league ||= if action_name == 'create'
                          Team.find_by(id: params[:team_id])&.league if params[:team_id].present?
                        else
                          League.find_by(id: @player.suspensions.find_by(id: params[:id])&.league_id)
                        end
    end

    # Zustaendige Spielbetriebe der HEIMATvereine des Spielers.
    #
    # Der Filter auf `home_club` fehlte, obwohl der Name der Methode und der
    # Kommentar an `sbk_may_suspend?` ihn beide behaupten („Eine Vereins-Freigabe
    # reicht dafuer ausdruecklich NICHT"). Gelesen wurde JEDE Zugehoerigkeit, ein
    # Zweitspielrecht also mit -- womit der Verband des aufnehmenden Vereins eine
    # spielerWEITE Sperre setzen konnte, die alle Lizenzantraege blockiert, auch
    # die im Heimatverband, mit dem er nichts zu tun hat.
    #
    # Erreichbar war das bisher nur ueber den mehrstufigen Antragsweg; seit die
    # Freigabe im Spielerprofil verbandsuebergreifend geht, genuegt ein Aufruf.
    # Die Luecke ist aelter als diese Aenderung, aber sie gehoert zu ihr.
    #
    # Gelesen wird nur das Merkmal, nicht zusaetzlich die Gueltigkeit. Zu
    # schliessen ist die Luecke, die eine ZWEITzugehoerigkeit aufreisst -- wer bei
    # einer abgelaufenen Heimatzugehoerigkeit noch sperren darf, ist eine eigene
    # Frage und waere hier eine zweite, unausgesprochene Verschaerfung. Sie traefe
    # vor allem die Profile, die vor api#472 deaktiviert wurden: Damals schloss
    # `Player#deactivate!` auch die Heimatzugehoerigkeit (heute laesst es sie
    # bewusst offen, gerade damit das Profil transferierbar bleibt), und was davon
    # nicht wieder geoeffnet wurde, koennte danach sein eigener Verband nicht mehr
    # sperren.
    #
    # Boolean-Cast wie in `Player#home_club_hash`: In Altdaten liegt das Merkmal
    # auch als Zeichenkette vor, und `'false'` ist in Ruby wahr.
    def player_home_game_operation_ids
      Club.where(id: player_home_club_ids).map(&:main_game_operation_id).compact.uniq
    end

    def player_home_club_ids
      heimat = (@player.clubs || []).select do |c|
        ActiveModel::Type::Boolean.new.cast(c['home_club'])
      end

      heimat.filter_map { |c| c['club_id']&.to_i }
    end

    def player_clubs_readable?(perm_hash)
      go_ids = perm_hash[:sbk].to_a.reject(&:zero?)
      return false if go_ids.empty?

      Club.where(id: player_club_ids).any? { |club| club.readable_by_game_operations?(go_ids) }
    end

    def player_club_ids
      (@player.clubs || []).filter_map { |c| c['club_id']&.to_i }
    end

    # Beim Anlegen kommt das Team aus den Parametern, beim Aufheben aus der
    # bestehenden Sperre. Ohne Team ist es eine spielerweite Sperre.
    def suspension_scope_team_id
      return params[:team_id].presence if action_name == 'create'

      @player.suspensions.find_by(id: params[:id])&.team_id
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def suspension_json(suspension)
      team = Team.find_by(id: suspension.team_id) if suspension.team_id.present?

      {
        id:          suspension.id,
        player_id:   suspension.player_id,
        team_id:     suspension.team_id,
        team_name:   team&.name,
        kind:        suspension.player_wide? ? 'application_block' : 'license_suspension',
        scope_kind:  suspension.scope_kind,
        scope_summary: suspension.scope_summary,
        league_id:   suspension.league_id,
        league_name: (League.unscoped.find_by(id: suspension.league_id)&.name if suspension.league_id),
        season_id:   suspension.season_id,
        game_operation_id: suspension.game_operation_id,
        age_group:   suspension.age_group,
        field_size:  suspension.field_size,
        competition_groups: Array(suspension.competition_groups),
        games_total:     suspension.games_total,
        games_served:    suspension.games_served,
        remaining_games: suspension.remaining_games,
        valid_from:  suspension.valid_from,
        valid_until: suspension.valid_until,
        reason:      suspension.reason,
        active:      suspension.active?,
        lifted_at:   suspension.lifted_at,
        affected_licenses_count: Array(suspension.affected_licenses).size,
        created_at:  suspension.created_at
      }
    end
  end
end
