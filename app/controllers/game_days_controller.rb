class GameDaysController < ApplicationController
  # GET /game_day_days
  def index
    @game_day_days = GameDay.all

    render json: @game_day_days
  end

  # GET /game_days/1
  def show
    game_day = GameDay.find(params[:id])

    hash = game_day.full_hash

    render json: hash
  end

  # POST /game_days
  def create
    ph = current_user.permission_hash
    game_day = GameDay.new(game_day_params)
    game_operation_id = game_day.league.game_operation_id.to_i

    allowed = if ph[:admin].present? || ph[:sbk].present?
                gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)

                gos.include?(0) || gos.include?(game_operation_id)
              else
                false
              end

    if allowed
      if game_day.save

        render json: { success: true }, status: :created
      else
        render json: { success: false, error: game_day.errors }, status: 400
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  # PATCH /game_days/1
  def update
    ph = current_user.permission_hash
    game_day = GameDay.find(params[:id])
    game_operation_id = game_day.league.game_operation_id.to_i

    allowed = if ph[:admin].present? || ph[:sbk].present?
                gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)

                gos.include?(0) || gos.include?(game_operation_id)
              else
                false
              end

    if allowed
      if game_day.update(game_day_params)

        render json: { success: true }
      else
        render json: { success: false, error: game_day.errors }, status: 400
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  # DELETE /game_days/1
  def destroy
    ph = current_user.permission_hash
    game_day = GameDay.find(params[:id])
    game_operation_id = game_day.league.game_operation_id.to_i

    allowed = if ph[:admin].present? || ph[:sbk].present?
                gos = [ph[:admin], ph[:sbk]].flatten.compact.map(&:to_i)

                gos.include?(0) || gos.include?(game_operation_id)
              else
                false
              end

    if allowed
      if game_day.deletable?
        game_day.destroy
        render json: { success: true }
      else
        render json: { success: false, error: 'Darf nicht gelöscht werden' }, status: 400
      end
    else
      render json: { message: 'Keine Berechtigung.' }, status: :forbidden
    end
  end

  def game_day_params
    params.require(:game_day).permit(:id, :arena_id, :club_id, :date,
                                     :league_id, :number)
  end
end
