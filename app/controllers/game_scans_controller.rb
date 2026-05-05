class GameScansController < ApplicationController
  before_action :set_game
  before_action :check_permission

  def show
    scan = @game.game_scan&.then { |s| s.expires_at > Time.current ? s : nil }

    if scan&.scan_file&.attached?
      render json: scan_json(scan)
    else
      render json: nil
    end
  end

  def create
    existing = @game.game_scan
    existing&.scan_file&.purge
    existing&.destroy

    scan = GameScan.new(
      game: @game,
      uploaded_by: current_user,
      expires_at: @game.game_day.date + 12.months
    )
    scan.scan_file.attach(params[:file])

    if scan.save
      render json: scan_json(scan), status: :created
    else
      render json: { errors: scan.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    ph = current_user.permission_hash
    unless ph[:admin].present? || ph[:sbk].present?
      return render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end

    scan = @game.game_scan
    if scan
      scan.scan_file.purge
      scan.destroy
      render json: { success: true }
    else
      render json: { message: 'Kein Scan vorhanden.' }, status: :not_found
    end
  end

  private

  def set_game
    @game = Game.find(params[:game_id])
  end

  def check_permission
    ph = current_user.permission_hash
    game_operation_id = @game.game_day.league.game_operation_id.to_i

    admin_or_sbk = if ph[:admin].present? || ph[:sbk].present?
                     gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)
                     gos.include?(0) || gos.include?(game_operation_id)
                   end

    hosting_club_id = @game.game_day.club_id
    vm_of_hosting_club = ph[:vm].present? && ph[:vm].include?(hosting_club_id)

    unless admin_or_sbk || vm_of_hosting_club
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def scan_json(scan)
    {
      filename: scan.scan_file.filename.to_s,
      content_type: scan.scan_file.content_type,
      byte_size: scan.scan_file.byte_size,
      expires_at: scan.expires_at.to_date,
      url: rails_blob_url(scan.scan_file, disposition: 'inline')
    }
  end
end
