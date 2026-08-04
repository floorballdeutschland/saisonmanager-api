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
      return render json: { message: 'Ablaufdatum fehlt oder ungültig.' }, status: :unprocessable_entity if valid_until.nil?

      valid_from = parse_date(params[:valid_from]) || Date.current
      team_id    = params[:team_id].presence

      suspension = @player.suspend!(
        team_id:,
        valid_from:,
        valid_until:,
        reason: params[:reason].presence,
        user_id: current_user.id
      )

      render json: suspension_json(suspension), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { message: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
    end

    def destroy
      suspension = @player.suspensions.find(params[:id])
      @player.lift_suspension!(suspension, user_id: current_user.id)
      render json: suspension_json(suspension.reload)
    end

    private

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
    # Spielers ist über den Heimat-Spielbetrieb oder eine Vereins-Freigabe
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
    # Heimatverband des Spielers setzen und aufheben – der Spielbetrieb, an dem
    # sein Verein als Heim-Spielbetrieb hängt.
    #
    # Eine Vereins-Freigabe reicht dafür ausdrücklich NICHT: Sie gewährt nur
    # Lesezugriff (siehe StateAssociationRelease und Club#user_permissions, wo
    # :update_club ebenfalls am Heim-Spielbetrieb hängt).
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
    def sbk_may_suspend?(perm_hash)
      return false if perm_hash[:sbk].blank?
      return true if sbk_global?(perm_hash)
      return true if (perm_hash[:sbk] & player_home_game_operation_ids).present?

      team = Team.find_by(id: suspension_scope_team_id)
      team.present? && sbk_can_access_team?(perm_hash, team)
    end

    # Heim-Spielbetriebe der Vereine des Spielers.
    def player_home_game_operation_ids
      Club.where(id: player_club_ids).map(&:main_game_operation_id).compact.uniq
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
