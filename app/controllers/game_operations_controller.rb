class GameOperationsController < ApplicationController
  before_action :set_game_operation, only: [:index_leagues]
  skip_before_action :authenticate_user, except: [:admin_game_operations]

  # GET /game_operations
  def index
    @game_operations = GameOperation.all.order(:id)

    render json: @game_operations
  end

  # GET /game_operations/1/leagues
  def index_leagues
    current_season = Setting.current_season

    leagues = @game_operation.leagues
    leagues = if params[:season_id]
                leagues.where(season_id: params[:season_id])
              else
                leagues.where(season_id: current_season)
              end

    render json: leagues.map(&:full_hash)
  end

  # GET /game_operations/by_shortname/:name
  def by_shortname
    @game_operation = GameOperation.find_by path: params[:name]
    render json: @game_operation
  end

  def admin_game_operations
    # für jeden verband:
    # name, id, kuerzel, ligen
    go_ids = []

    # wenn admin oder sbk global: füge alle hinzu
    ph = current_user.permission_hash
    if ph[:admin]&.include?(0) || ph[:sbk]&.include?(0)
      go_ids = GameOperation.all.pluck(:id)
    elsif ph[:admin].present? || ph[:sbk].present?
      go_ids << ph[:admin] if ph[:admin].present?
      go_ids << ph[:sbk] if ph[:sbk].present?
      go_ids.flatten
    end

    render json: GameOperation.find(go_ids)
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_game_operation
    @game_operation = GameOperation.find(params[:id])
  end
end
