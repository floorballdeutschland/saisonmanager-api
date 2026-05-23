class GameOperationsController < ApplicationController
  before_action :set_game_operation, only: %i[index_leagues admin_upload_banner admin_delete_banner]
  skip_before_action :authenticate_user, except: %i[admin_game_operations admin_upload_banner admin_delete_banner]
  before_action :authenticate_public_request, except: %i[admin_game_operations admin_upload_banner admin_delete_banner]

  # GET /game_operations
  def index
    @game_operations = GameOperation.all.order(:id)

    render json: @game_operations
  end

  # GET /game_operations/1/leagues
  def index_leagues
    current_season_id = Setting.current_season_id

    leagues = @game_operation.leagues
    leagues = if params[:season_id]
                leagues.where(season_id: params[:season_id])
              else
                leagues.where(season_id: current_season_id)
              end

    render json: leagues.map(&:full_hash)
  end

  # GET /game_operations/by_shortname/:name
  def by_shortname
    @game_operation = GameOperation.find_by path: params[:name]
    render json: @game_operation
  end

  def admin_game_operations
    go_ids = []

    ph = current_user.permission_hash
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten!
    elsif ph[:vm].present?
      go_ids = Club.where(id: ph[:vm])
                   .flat_map { |c| [c.main_game_operation_id, *c.additional_game_operation_ids] }
                   .compact.uniq
    end

    render json: GameOperation.where(id: go_ids).order(:id)
  end

  def admin_upload_banner
    ph = current_user.permission_hash
    unless ph[:admin].present?
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    return render json: { message: 'Kein Bild angefügt' }, status: :unprocessable_entity unless params[:banner].present?

    unless params[:banner].content_type == 'image/webp'
      return render json: { message: 'Nur WebP-Dateien erlaubt' }, status: :unprocessable_entity
    end

    if params[:banner].size > 500.kilobytes
      return render json: { message: 'Maximale Dateigröße: 500 KB' }, status: :unprocessable_entity
    end

    @game_operation.banner.attach(params[:banner])
    render json: { banner_url: @game_operation.banner_url }
  end

  def admin_delete_banner
    ph = current_user.permission_hash
    unless ph[:admin].present?
      return render json: { message: 'Keine Berechtigung' }, status: :forbidden
    end

    @game_operation.banner.purge
    render json: { success: true }
  end

  private

  def set_game_operation
    @game_operation = GameOperation.find(params[:id])
  end
end
