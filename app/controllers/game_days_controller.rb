class GameDaysController < ApplicationController
  # GET /game_day_days
  def index
    @game_day_days = GameDay.all

    render json: @game_day_days
  end

  # POST /game_days
  def create
    game_day = GameDay.new(game_day_params)

    allowed = if ph[:admin].present? || ph[:sbk].present?
                # TODO: Check if correct association
                true
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
    allowed = if ph[:admin].present? || ph[:sbk].present?
                # TODO: Check if correct association
                true
              else
                false
              end

    if allowed
      game_day = GameDay.find(params[:id])
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
    game_day = GameDay.find(params[:id])

    allowed = if ph[:admin].present? || ph[:sbk].present?
                # TODO: Check if correct association
                true
              else
                false
              end

    # TODO: check if game_day can be deleted!
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
    params.require(:game_day).permit(:forfait, :game_day_day_id, :game_day_number, :start_time,
                                     :nominated_referee_string, :notice_type, :notice_string,
                                     :home_team_id, :guest_team_id)
  end
end
