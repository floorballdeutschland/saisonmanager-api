module Admin
  # Pflege der dauerhaft abgewiesenen Adressen, Teil der Admin-Seite "System".
  # Nur Admin: Eine Sperre wirkt vor allem anderen, eine falsch eingetragene
  # Adresse nimmt im schlimmsten Fall eine ganze Nutzergruppe vom Netz.
  class BlockedIpsController < ApplicationController
    before_action :authorize_admin!

    # GET /api/v2/admin/blocked_ips
    def index
      render json: BlockedIp.order(created_at: :desc).map { |b| blocked_ip_json(b) }
    end

    # POST /api/v2/admin/blocked_ips
    def create
      blocked = BlockedIp.new(blocked_ip_params)
      blocked.created_by = current_user.id

      if blocked.save
        render json: blocked_ip_json(blocked), status: :created
      else
        render json: { errors: blocked.errors.full_messages }, status: :unprocessable_entity
      end
    end

    # DELETE /api/v2/admin/blocked_ips/:id
    def destroy
      blocked = BlockedIp.find(params[:id])
      blocked.destroy!
      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Eintrag nicht gefunden' }, status: :not_found
    end

    private

    def blocked_ip_params
      params.require(:blocked_ip).permit(:ip, :reason)
    end

    def blocked_ip_json(blocked)
      {
        id: blocked.id,
        ip: blocked.ip,
        reason: blocked.reason,
        created_at: blocked.created_at,
        created_by_name: User.find_by(id: blocked.created_by)&.full_with_username
      }
    end

    def authorize_admin!
      return if current_user.permission_hash[:admin].present?

      render json: { error: 'Nicht berechtigt' }, status: :forbidden
    end
  end
end
