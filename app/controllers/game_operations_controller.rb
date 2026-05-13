class GameOperationsController < ApplicationController
  before_action :set_game_operation, only: [:index_leagues]
  skip_before_action :authenticate_user, except: [:admin_game_operations]
  before_action :authenticate_public_request, except: [:admin_game_operations]

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

  private

  def set_game_operation
    @game_operation = GameOperation.find(params[:id])
  end
end
