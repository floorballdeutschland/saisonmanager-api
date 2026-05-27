module Admin
  class PlayerSuspensionsController < ApplicationController
    before_action :set_player
    before_action :check_permission

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

    def check_permission
      ph = current_user.permission_hash
      return if ph[:admin].present? || ph[:sbk].present?

      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
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
